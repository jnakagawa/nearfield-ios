import Foundation

// Swift port of the simulator's nearfield-core (spec §5, §13). The JS core is
// the reference implementation; this port is validated against golden
// trajectories in config/fixtures/reward_golden.json (tolerance 1e-3, spec §9).
// Model cadence is 5 Hz — presentation layers re-smooth per frame.

// MARK: - deterministic PRNG (must match JS mulberry32 exactly)

struct Mulberry32 {
    private var state: UInt32
    init(seed: UInt32) { state = seed }
    mutating func next() -> Double {
        state = state &+ 0x6D2B79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296.0
    }
    // Box-Muller, same call order as the JS gaussian()
    mutating func gaussian() -> Double {
        var u = 0.0, v = 0.0
        while u == 0 { u = next() }
        while v == 0 { v = next() }
        return (-2.0 * log(u)).squareRoot() * cos(2.0 * .pi * v)
    }
}

func fnv1a(_ s: String) -> UInt32 {
    var h: UInt32 = 0x811c9dc5
    for u in s.utf16 { // JS charCodeAt == UTF-16 code unit
        h ^= UInt32(u)
        h = h &* 0x01000193
    }
    return h
}

// MARK: - small utilities (§5)

func emaAlpha(dt: Double, tau: Double) -> Double { 1 - exp(-dt / tau) }
func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }
func smoothstep(_ x: Double) -> Double { let t = clamp(x, 0, 1); return t * t * (3 - 2 * t) }
func centsBetween(_ f1: Double, _ f2: Double) -> Double { 1200 * log2(f2 / f1) }

func foldCents(_ c: Double, pseudoOctaveCents p: Double) -> Double {
    ((c.truncatingRemainder(dividingBy: p)) + p).truncatingRemainder(dividingBy: p)
}

/// Nearest dip to a folded interval; wrap-aware (§5.3). Returns delta = dip − folded.
func nearestDipDelta(intervalCents: Double, dips: [Double]) -> Double {
    guard let pseudo = dips.last else { return .infinity }
    let folded = foldCents(intervalCents, pseudoOctaveCents: pseudo)
    var best = Double.infinity
    for dip in dips {
        for cand in [dip, dip - pseudo] {
            let delta = cand - folded
            if abs(delta) < abs(best) { best = delta }
        }
    }
    return best
}

/// Ombak mode (§13.3): cents scale by ref/f so beat rates stay even across registers.
func ombakScale(freqHz: Double, params: Params) -> Double {
    guard params.drift.ombakEnabled else { return 1 }
    return clamp(params.drift.ombakRefHz / freqHz, 0.25, 3)
}

// MARK: - sensing pipeline (§5.1)

enum Bucket: String { case near, mid, far }

final class PairSensor {
    private let p: Params.Sensing
    private var smoothed: Double?
    private(set) var bucket: Bucket = .far
    private var sinceHeard = 0.0
    private var nearTime = 0.0
    private var awayTime = 0.0
    private(set) var encounterActive = false

    init(params: Params) { p = params.sensing }

    @discardableResult
    func update(dt: Double, rawRssi: Double?) -> (bucket: Bucket, encounterActive: Bool) {
        if let raw = rawRssi {
            sinceHeard = 0
            if let s = smoothed {
                smoothed = s + (raw - s) * emaAlpha(dt: dt, tau: p.rssiEmaTauS)
            } else {
                smoothed = raw
            }
            let s = smoothed!
            switch bucket {
            case .near:
                if s < p.rssiNearExitDbm { bucket = s < p.rssiMidExitDbm ? .far : .mid }
            case .mid:
                if s >= p.rssiNearEnterDbm { bucket = .near }
                else if s < p.rssiMidExitDbm { bucket = .far }
            case .far:
                if s >= p.rssiNearEnterDbm { bucket = .near }
                else if s >= p.rssiMidEnterDbm { bucket = .mid }
            }
        } else {
            sinceHeard += dt
            if sinceHeard > p.farTimeoutS { bucket = .far }
        }
        if !encounterActive {
            nearTime = bucket == .near ? nearTime + dt : 0
            if nearTime >= p.encounterOnS { encounterActive = true; awayTime = 0 }
        } else {
            awayTime = bucket != .near ? awayTime + dt : 0
            if awayTime >= p.encounterOffS { encounterActive = false; nearTime = 0 }
        }
        return (bucket, encounterActive)
    }
}

// MARK: - fingerprint drift (§13.2)

final class FingerprintDrift {
    private var rng: Mulberry32
    private let params: Params
    private let roleMult: Double
    private let freqHz: Double
    private var c = 0.0

    init(seed: UInt32, params: Params, roleMult: Double = 1, freqHz: Double = 300) {
        rng = Mulberry32(seed: seed)
        self.params = params
        self.roleMult = roleMult
        self.freqHz = freqHz
    }

    func update(dt: Double, amplitude: Double = 1) -> Double {
        let maxC = params.drift.fingerprintMaxCents * roleMult * ombakScale(freqHz: freqHz, params: params)
        let tau = params.drift.fingerprintTauS
        let sigma = (maxC / 3) * (2 / tau).squareRoot()
        c += (-c / tau) * dt + sigma * dt.squareRoot() * rng.gaussian()
        c = clamp(c, -maxC, maxC)
        return c * amplitude
    }
}

// MARK: - reward model (§5.2–§5.4)

struct RewardInputs {
    var encounters: [Int: Bool]
    var buckets: [Int: Bucket]
    var motion: Double
    var peerPitches: [Int: Double]
    var bloomMultiplier: Double = 1
}

struct RewardOutputs {
    var W = 0.0, B = 0.0, E = 0.0, F = 0.0
    var novelty = 0.0
    var focusId: Int? = nil
    var partialGains: [Double] = [1, 0, 0, 0]
    var detuneCents = 0.0
    var amRate = 0.1, amDepth = 0.0
}

final class RewardState {
    private let meId: Int
    private let role: String
    private let pitchHz: Double
    private let params: Params
    private let scale: Scale

    private var t = 0.0
    private var W = 0.0
    private var E: [Int: Double] = [:]
    private var F: [Int: Double] = [:]
    private struct Contact { var inContact: Bool; var novel: Bool; var contactStart: Double; var lastContactEnd: Double }
    private var contacts: [Int: Contact] = [:]
    private var partialGainsSm: [Double] = [1, 0, 0, 0]
    private var detuneOut = 0.0
    private var focusId: Int?

    init(id: Int, role: String, pitchHz: Double, params: Params, scale: Scale) {
        meId = id
        self.role = role
        self.pitchHz = pitchHz
        self.params = params
        self.scale = scale
    }

    func update(dt: Double, _ inputs: RewardInputs) -> RewardOutputs {
        let p = params
        guard let roleP = p.roles[role] else { return RewardOutputs() }
        t += dt

        // novelty (§5.1) — iterate sorted for determinism (JS uses insertion order;
        // fixtures avoid order-sensitive ties)
        var significant = 0, novel = 0
        for (id, bucket) in inputs.buckets.sorted(by: { $0.key < $1.key }) {
            let sig = bucket == .near || bucket == .mid
            var c = contacts[id]
            if sig {
                if c == nil || !(c!.inContact) {
                    let fresh = c == nil || (t - c!.lastContactEnd) > p.wind.noveltyWindowS
                    c = Contact(inContact: true, novel: fresh, contactStart: t,
                                lastContactEnd: c?.lastContactEnd ?? -.infinity)
                    contacts[id] = c
                }
                if c!.novel && t - c!.contactStart > p.wind.noveltyWindowS {
                    contacts[id]!.novel = false
                    c!.novel = false
                }
                significant += 1
                if c!.novel { novel += 1 }
            } else if var cc = c, cc.inContact {
                cc.inContact = false
                cc.lastContactEnd = t
                contacts[id] = cc
            }
        }
        let novelty = significant > 0 ? Double(novel) / Double(significant) : 0

        // wind reservoir
        W = clamp(W + (p.wind.alphaMotionPerS * inputs.motion +
                       p.wind.alphaNoveltyPerS * novelty -
                       W / p.wind.tauWindS) * dt, 0, 1)

        // encounter envelopes + familiarity
        for (id, active) in inputs.encounters.sorted(by: { $0.key < $1.key }) {
            let e = E[id] ?? 0
            let f = F[id] ?? 0
            if active {
                E[id] = e + (1 - e) * emaAlpha(dt: dt, tau: p.encounter.tauAttackS)
                F[id] = f + (1 - f) * emaAlpha(dt: dt, tau: p.encounter.tauFamiliarityS)
            } else {
                E[id] = e * (1 - emaAlpha(dt: dt, tau: p.encounter.tauReleaseS))
                F[id] = f * (1 - emaAlpha(dt: dt, tau: p.encounter.tauFamiliarityReleaseS))
            }
        }

        // sticky focus (§5.2): challenger must beat the incumbent by 15%
        let beta = p.bloom.betaFamiliarity
        func score(_ id: Int) -> Double { (E[id] ?? 0) * (1 - beta * (F[id] ?? 0)) }
        var bestId: Int? = nil
        var bestScore = 0.0
        for id in E.keys.sorted() {
            let s = score(id)
            if s > bestScore { bestScore = s; bestId = id }
        }
        let incumbent = focusId.map(score) ?? 0
        if bestId != focusId && bestScore > incumbent * 1.15 { focusId = bestId }
        if let f = focusId, score(f) < 0.005 { focusId = nil }
        let focusScore = focusId.map(score) ?? 0
        let Braw = focusScore * (p.bloom.gainBase + p.bloom.gainWind * W)
        let B = Braw * roleP.bloomScale * inputs.bloomMultiplier

        // partial gains (roles cap partial count, §5.4)
        let amps = scale.spectrum.amps
        let gate = roleP.motionGate ? clamp(2 * inputs.motion, 0, 1) : 1
        for k in 2...4 {
            var target = 0.0
            if k <= roleP.maxPartials {
                let th = p.bloom.partialThresholds[k - 2]
                target = amps[k - 1] * smoothstep((B - th) / p.bloom.thresholdWidth) * gate
            }
            let g = partialGainsSm[k - 1]
            let tau = target > g ? p.bloom.gainAttackS : p.bloom.gainReleaseS
            partialGainsSm[k - 1] = g + (target - g) * emaAlpha(dt: dt, tau: tau)
        }

        // resolution slew (§5.3) with ombak scaling (§13.3)
        var detuneTarget = 0.0
        if roleP.slew, let fid = focusId, let peerPitch = inputs.peerPitches[fid] {
            let nominal = centsBetween(pitchHz, peerPitch)
            let delta = nearestDipDelta(intervalCents: nominal, dips: scale.dipIntervalsCents)
            if abs(delta) <= p.slew.dipMaxDistanceCents {
                let e = E[fid] ?? 0
                let dir: Double = meId < fid ? 1 : -1
                detuneTarget = dir * p.slew.centsStart * ombakScale(freqHz: pitchHz, params: p) * (1 - e)
                    + 0.5 * delta * e
            }
        }
        let maxStep = p.slew.centsPerSMax * dt
        detuneOut += clamp(detuneTarget - detuneOut, -maxStep, maxStep)

        // shimmer AM
        let amRate = p.shimmerAm.rateBaseHz + p.shimmerAm.rateMotionHz * inputs.motion
        let amDepth = p.shimmerAm.depthWind * W * roleP.amDepthScale

        // prune dead envelopes
        for (id, e) in E where e < 0.001 && !(inputs.encounters[id] ?? false) {
            E.removeValue(forKey: id)
        }

        var out = RewardOutputs()
        out.W = W
        out.B = B
        out.novelty = novelty
        out.focusId = focusId
        out.E = focusId.flatMap { E[$0] } ?? 0
        out.F = focusId.flatMap { F[$0] } ?? 0
        out.partialGains = partialGainsSm
        out.detuneCents = detuneOut
        out.amRate = amRate
        out.amDepth = amDepth
        return out
    }
}
