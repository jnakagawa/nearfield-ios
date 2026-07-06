import Foundation
import Combine

// The 5 Hz loop (spec §5.1 cadence): sensors -> RewardState -> VoiceEngine.
// In the iOS Simulator (no BLE) or for soundcheck, the debug injection fakes
// one peer's RSSI and the motion level (spec §9: "a device debug panel fakes
// bucket/motion inputs so the full loop runs in the iOS simulator").
@MainActor
final class Conductor: ObservableObject {
    @Published private(set) var lastOut = RewardOutputs()
    @Published private(set) var fpCents = 0.0
    @Published var debugEnabled = false
    @Published var debugPeerRssi: Double = -85
    @Published var debugMotion: Double = 0.3

    let neighbors = NeighborSensor()
    let motionSensor = MotionSensor()

    private var reward: RewardState?
    private var fingerprint: FingerprintDrift?
    private var params: Params?
    private var scale: Scale?
    private var timer: Timer?
    private var tickCount = 0
    private var debugSensor: PairSensor?
    private weak var voice: VoiceEngine?
    private weak var hub: HubClient?
    weak var visual: VisualBridge?
    private var currentPitch = 220.0
    private var currentRatios: [Double] = [1, 2.07, 3.2, 4.4]

    // score playback (spec §12): free-runs from the last hub heartbeat
    @Published private(set) var scoreLabel: String?
    @Published private(set) var scoreT: Double = 0
    private var scoreEngine: ScoreEngine?
    private var driftTable: ScaleDrift?
    private var assignment: AssignMessage?
    private var breathPhase = 0.0
    private var gongStartedAt: Double? // in score seconds
    private var lastFingerprintAmp = 1.0

    static let tickS = 0.2
    private let debugPeerId = 5 // a voice-role id: consonant with most degrees

    func start(assignment a: AssignMessage, voice: VoiceEngine, hub: HubClient) {
        self.voice = voice
        self.hub = hub
        assignment = a
        params = a.params
        scale = a.scale
        if let sc = a.score { scoreEngine = ScoreEngine(score: sc, params: a.params) }
        driftTable = a.scaleDrift
        currentPitch = a.pitchHz
        currentRatios = a.scale.spectrum.ratios
        visual?.initialize(seedString: "\(a.participantId)|\(a.performanceId)|visual")
        reward = RewardState(id: a.participantId, role: a.role, pitchHz: a.pitchHz,
                             params: a.params, scale: a.scale)
        let mult = a.params.drift.roleMultipliers[a.role] ?? 1
        fingerprint = FingerprintDrift(
            seed: fnv1a("\(hub.deviceId)|\(a.performanceId)"),
            params: a.params, roleMult: mult, freqHz: a.pitchHz)
        debugSensor = PairSensor(params: a.params)
        #if targetEnvironment(simulator)
        debugEnabled = true // no BLE in the simulator
        #else
        neighbors.start(participantId: a.participantId, params: a.params)
        #endif
        motionSensor.start(params: a.params)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickS, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let reward, let fingerprint, var params, let scale, let a = assignment else { return }
        let dt = Self.tickS

        // --- score position: free-run from the last heartbeat (§12.3) --------
        var bloomMultiplier = 1.0
        var masterMultiplier = 1.0
        var fingerprintAmp = params.drift.fingerprintAmplitude
        var entryGate = 1.0
        var anchorSwellOverride: Double? = nil
        let scoreRunning = hub?.scorePosition != nil
        if scoreRunning, let engine = scoreEngine, let pos = hub?.scorePosition {
            let t = min(pos.t + Date().timeIntervalSince(pos.at), 960)
            scoreT = t
            let st = engine.tick(t)
            scoreLabel = st.label
            bloomMultiplier = st.bloomMultiplier
            masterMultiplier = st.masterMultiplier
            fingerprintAmp = st.fingerprintAmplitude
            // live param patches (§12.3) feed the reward model
            if let v = engine.valueAt("encounter.tau_attack_s", t) { params.encounter.tauAttackS = v }
            if let v = engine.valueAt("wind.alpha_novelty_per_s", t) { params.wind.alphaNoveltyPerS = v }
            if let v = engine.valueAt("shimmer_am.depth_wind", t) { params.shimmerAm.depthWind = v }
            if let v = engine.valueAt("breath.period_s", t) { params.breath.periodS = v }
            reward.updateParams(params)
            // tuning drift (§13.1): pitch glides as the scale ages
            if let table = driftTable {
                let row = interpolateScale(table, stretch: st.stretch)
                let register = Double(a.register)
                let pitch = scale.baseFreqHz * pow(row.stretch, register)
                    * pow(2, row.scaleCents[a.degreeIndex] / 1200)
                voice?.setTuning(pitchHz: pitch, ratios: row.spectrum.ratios)
                currentPitch = pitch
                currentRatios = row.spectrum.ratios
                // (slew dips shift a few cents under drift; RewardState keeps the
                // base scale — inside the 60¢ window, acceptable approximation)
            }
            // buka entry stagger (§12.2): anchors at 0, others across the section
            if a.role != "anchor" {
                let bukaLen = 120.0
                let n = max(pos.n - 1, 1)
                let entryAt = Double(a.participantId % max(n, 1) + 1) * (bukaLen / Double(n + 1))
                entryGate = t >= entryAt ? 1.0 : 0.0
            }
            // section/final gongs: anchors swell together for 20 s
            if st.events.contains(where: { $0.type == "section_gong" || $0.type == "final_gong" }) {
                gongStartedAt = t
            }
            if a.role == "anchor", let g = gongStartedAt, t - g < 20 {
                anchorSwellOverride = sin(.pi * (t - g) / 20)
            }
        }
        lastFingerprintAmp = fingerprintAmp

        // breath (§5.3): local phase, period follows live params
        breathPhase += 2 * .pi * dt / params.breath.periodS
        let breathGain = 1 + params.breath.ensembleDepth * sin(breathPhase)
        var anchorEnv = 1.0
        if a.role == "anchor" {
            if let o = anchorSwellOverride {
                anchorEnv = o
            } else {
                let offset = 2 * .pi * Double(a.participantId % 8) / 8
                anchorEnv = 0.5 + 0.5 * sin(breathPhase + offset)
            }
        }
        voice?.setEnvelope(level: breathGain * anchorEnv * masterMultiplier * entryGate)

        var buckets: [Int: Bucket]
        var encounters: [Int: Bool]
        var motion: Double
        if debugEnabled {
            let out = debugSensor!.update(dt: dt, rawRssi: debugPeerRssi)
            buckets = [debugPeerId: out.bucket]
            encounters = [debugPeerId: out.encounterActive]
            motion = debugMotion
        } else {
            let sensed = neighbors.tick(dt: dt)
            buckets = sensed.buckets
            encounters = sensed.encounters
            motion = motionSensor.motion
        }

        // peers' pitches are derivable from their ids (deterministic assignment)
        var peerPitches: [Int: Double] = [:]
        for id in buckets.keys {
            peerPitches[id] = assignmentFor(index: id, scale: scale, params: params).pitchHz
        }

        let out = reward.update(dt: dt, RewardInputs(
            encounters: encounters, buckets: buckets,
            motion: motion, peerPitches: peerPitches,
            bloomMultiplier: bloomMultiplier))
        let fp = fingerprint.update(dt: dt, amplitude: fingerprintAmp)
        lastOut = out
        fpCents = fp
        voice?.applyReward(out, extraCents: fp)

        // §14 visual layer: same state that drives the audio
        if let v = visual {
            let peers = reward.topPeers(3).map { p -> (id: Int, e: Double, freq: Double) in
                let freq = peerPitches[p.id]
                    ?? assignmentFor(index: p.id, scale: scale, params: params).pitchHz
                return (p.id, p.e, freq)
            }
            v.push(pitch: currentPitch, cents: out.detuneCents + fp,
                   gains: out.partialGains, W: out.W, fpAmp: fingerprintAmp,
                   breathPhase: breathPhase, ratios: currentRatios, peers: peers)
        }

        tickCount += 1
        if tickCount % 5 == 0 { // 1 Hz telemetry (§6.1)
            hub?.sendTelemetry([
                "type": "telemetry",
                "W": out.W, "B": out.B,
                "focus": out.focusId ?? -1,
                "detune_cents": out.detuneCents + fp,
            ])
        }
    }
}
