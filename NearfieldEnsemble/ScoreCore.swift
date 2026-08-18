import Foundation

// Swift port of the simulator's ScoreState + interpolateScale (spec §12.3,
// §13.1) — validated against golden samples in reward_golden.json.
// Interpolation rule: each path's mentions form a piecewise-linear curve;
// before the first mention a path holds that first value, after the last it
// holds the last. Events fire once, in (prevT, t].
final class ScoreEngine {
    private let score: Score
    private let params: Params
    private var curves: [String: [(t: Double, v: Double)]] = [:]
    private var events: [Score.Event]
    private var prevT = -1.0

    init(score: Score, params: Params) {
        self.score = score
        self.params = params
        for kf in score.keyframes {
            for (path, v) in kf.patch {
                curves[path, default: []].append((kf.atS, v))
            }
        }
        for k in curves.keys { curves[k]!.sort { $0.t < $1.t } }
        events = score.events.sorted { $0.atS < $1.atS }
    }

    func valueAt(_ path: String, _ t: Double) -> Double? {
        guard let pts = curves[path], let first = pts.first else { return nil }
        if t <= first.t { return first.v }
        for i in 1..<pts.count where t <= pts[i].t {
            let (t0, v0) = pts[i - 1]
            let (t1, v1) = pts[i]
            return v0 + (v1 - v0) * (t - t0) / (t1 - t0)
        }
        return pts.last!.v
    }

    func labelAt(_ t: Double) -> String {
        var label = score.keyframes.first?.label ?? ""
        for kf in score.keyframes where t >= kf.atS { label = kf.label }
        return label
    }

    func stretchAt(_ t: Double) -> Double {
        let d = params.drift
        let f = clamp(t / dGlobalStretchEndS, 0, 1)
        return dGlobalStretchFrom + (dGlobalStretchTo - dGlobalStretchFrom) * f
    }

    // drift trajectory constants (§13.1); params.drift lacks end_s in older
    // configs, so default to the spec value
    private var dGlobalStretchFrom: Double { params.drift.globalStretchFrom ?? 2.04 }
    private var dGlobalStretchTo: Double { params.drift.globalStretchTo ?? 2.1 }
    private var dGlobalStretchEndS: Double { params.drift.globalStretchEndS ?? 840 }

    func seek(_ t: Double) { prevT = t }

    struct Tick {
        let label: String
        let events: [Score.Event]
        let bloomMultiplier: Double
        let masterMultiplier: Double
        let fingerprintAmplitude: Double
        let stretch: Double
    }

    func tick(_ t: Double) -> Tick {
        let fired = events.filter { $0.atS > prevT && $0.atS <= t }
        prevT = t
        return Tick(
            label: labelAt(t),
            events: fired,
            bloomMultiplier: valueAt("bloom_multiplier", t) ?? 1,
            masterMultiplier: valueAt("master_multiplier", t) ?? 1,
            fingerprintAmplitude: valueAt("drift.fingerprint_amplitude", t) ?? 1,
            stretch: stretchAt(t))
    }
}

/// Interpolate the drifting scale between precomputed sweep rows (§13.1).
func interpolateScale(_ drift: ScaleDrift, stretch: Double) -> ScaleDrift.Row {
    let rows = drift.rows
    guard let first = rows.first, let last = rows.last else {
        fatalError("empty scale_drift")
    }
    if stretch <= first.stretch { return first }
    for i in 1..<rows.count where stretch <= rows[i].stretch {
        let a = rows[i - 1], b = rows[i]
        let f = (stretch - a.stretch) / (b.stretch - a.stretch)
        func lerp(_ x: [Double], _ y: [Double]) -> [Double] {
            zip(x, y).map { $0 + ($1 - $0) * f }
        }
        return ScaleDrift.Row(
            stretch: stretch,
            spectrum: Scale.Spectrum(ratios: lerp(a.spectrum.ratios, b.spectrum.ratios),
                                     amps: a.spectrum.amps),
            scaleCents: lerp(a.scaleCents, b.scaleCents),
            dipIntervalsCents: lerp(a.dipIntervalsCents, b.dipIntervalsCents))
    }
    return last
}
