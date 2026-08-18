import XCTest
@testable import NearfieldEnsemble

// Score engine + drift-scale interpolation vs golden samples (spec §12.3, §13.1).
final class ScoreCoreTests: XCTestCase {

    struct Golden: Codable {
        let score: ScoreSamples
        let scaleDrift: DriftSamples
        struct ScoreSamples: Codable { let samples: [Sample] }
        struct Sample: Codable {
            let t: Double, bloom: Double, master: Double, fpAmp: Double
            let breath: Double, tauAttack: Double, novelty: Double, stretch: Double
            let label: String
        }
        struct DriftSamples: Codable { let samples: [DriftSample] }
        struct DriftSample: Codable {
            let stretch: Double
            let scaleCents: [Double]
            let dips: [Double]
            let ratio2: Double
        }
    }

    private var golden: Golden!
    private var params: Params!
    private var score: Score!
    private var drift: ScaleDrift!

    override func setUpWithError() throws {
        let bundle = Bundle(for: ScoreCoreTests.self)
        func load<T: Decodable>(_ name: String, _ type: T.Type) throws -> T {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"), "missing \(name).json")
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        }
        golden = try load("reward_golden", Golden.self)
        params = try load("params", Params.self)
        score = try load("score", Score.self)
        drift = try load("scale_drift", ScaleDrift.self)
    }

    func testScoreEngineMatchesSamples() {
        let engine = ScoreEngine(score: score, params: params)
        for s in golden.score.samples {
            XCTAssertEqual(engine.labelAt(s.t), s.label, "label at \(s.t)")
            XCTAssertEqual(engine.valueAt("bloom_multiplier", s.t) ?? -1, s.bloom, accuracy: 1e-9, "bloom at \(s.t)")
            XCTAssertEqual(engine.valueAt("master_multiplier", s.t) ?? -1, s.master, accuracy: 1e-9, "master at \(s.t)")
            XCTAssertEqual(engine.valueAt("drift.fingerprint_amplitude", s.t) ?? -1, s.fpAmp, accuracy: 1e-9, "fpAmp at \(s.t)")
            XCTAssertEqual(engine.valueAt("breath.period_s", s.t) ?? -1, s.breath, accuracy: 1e-9, "breath at \(s.t)")
            XCTAssertEqual(engine.valueAt("encounter.tau_attack_s", s.t) ?? -1, s.tauAttack, accuracy: 1e-9, "tauAttack at \(s.t)")
            XCTAssertEqual(engine.valueAt("wind.alpha_novelty_per_s", s.t) ?? -1, s.novelty, accuracy: 1e-9, "novelty at \(s.t)")
            XCTAssertEqual(engine.stretchAt(s.t), s.stretch, accuracy: 1e-9, "stretch at \(s.t)")
        }
    }

    func testScoreEventsFireOnce() {
        let engine = ScoreEngine(score: score, params: params)
        engine.seek(0)
        XCTAssertTrue(engine.tick(100).events.isEmpty)
        let at130 = engine.tick(130)
        XCTAssertEqual(at130.events.count, 1)
        XCTAssertEqual(at130.events.first?.type, "section_gong")
        XCTAssertTrue(engine.tick(131).events.isEmpty, "no refire")
        engine.seek(830)
        XCTAssertEqual(engine.tick(850).events.first?.type, "final_gong")
    }

    func testInterpolateScaleMatchesSamples() {
        for s in golden.scaleDrift.samples {
            let row = interpolateScale(drift, stretch: s.stretch)
            XCTAssertEqual(row.spectrum.ratios[1], s.ratio2, accuracy: 1e-6, "ratio2 at \(s.stretch)")
            for (a, b) in zip(row.scaleCents, s.scaleCents) {
                XCTAssertEqual(a, b, accuracy: 1e-6, "scale cents at \(s.stretch)")
            }
            for (a, b) in zip(row.dipIntervalsCents, s.dips) {
                XCTAssertEqual(a, b, accuracy: 1e-6, "dips at \(s.stretch)")
            }
        }
    }
}
