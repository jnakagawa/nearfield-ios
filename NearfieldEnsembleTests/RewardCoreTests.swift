import XCTest
@testable import NearfieldEnsemble

// Replays the golden trajectories generated from the tested JS core
// (config/fixtures/reward_golden.json). Spec §9: match within 1e-3.
final class RewardCoreTests: XCTestCase {

    struct Golden: Codable {
        let dt: Double
        let prng: Prng
        let pairSensor: Pair
        let fingerprint: Fp
        let reward: Rew

        struct Prng: Codable { let seed: UInt32; let raw: [Double]; let gaussian: [Double] }
        struct Pair: Codable { let trace: [PairTick] }
        struct PairTick: Codable { let rssi: Double; let bucket: String; let encounter: Int }
        struct Fp: Codable { let seed: UInt32; let freqHz: Double; let roleMult: Double; let trace: [Double] }
        struct Rew: Codable { let me: Me; let peer2PitchHz: Double; let trace: [RewTick] }
        struct Me: Codable { let id: Int; let role: String; let pitchHz: Double }
        struct RewTick: Codable {
            let W: Double, B: Double, E: Double, F: Double
            let novelty: Double, detune: Double, g2: Double, g3: Double
            let focusId: Int
        }
    }

    private var golden: Golden!
    private var params: Params!
    private var scale: Scale!

    override func setUpWithError() throws {
        let bundle = Bundle(for: RewardCoreTests.self)
        func load<T: Decodable>(_ name: String, _ type: T.Type) throws -> T {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"), "missing \(name).json")
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        }
        golden = try load("reward_golden", Golden.self)
        params = try load("params", Params.self)
        scale = try load("scale", Scale.self)
    }

    func testPrngMatchesJS() {
        var rng = Mulberry32(seed: golden.prng.seed)
        for (i, expected) in golden.prng.raw.enumerated() {
            XCTAssertEqual(rng.next(), expected, accuracy: 1e-12, "raw[\(i)]")
        }
        var g = Mulberry32(seed: golden.prng.seed)
        for (i, expected) in golden.prng.gaussian.enumerated() {
            XCTAssertEqual(g.gaussian(), expected, accuracy: 1e-9, "gaussian[\(i)]")
        }
    }

    func testPairSensorMatchesTrace() {
        let sensor = PairSensor(params: params)
        for (i, tick) in golden.pairSensor.trace.enumerated() {
            let out = sensor.update(dt: golden.dt, rawRssi: tick.rssi)
            XCTAssertEqual(out.bucket.rawValue, tick.bucket, "bucket at tick \(i)")
            XCTAssertEqual(out.encounterActive ? 1 : 0, tick.encounter, "encounter at tick \(i)")
        }
    }

    func testFingerprintMatchesTrace() {
        let fp = FingerprintDrift(seed: golden.fingerprint.seed, params: params,
                                  roleMult: golden.fingerprint.roleMult,
                                  freqHz: golden.fingerprint.freqHz)
        for (i, expected) in golden.fingerprint.trace.enumerated() {
            let t = Double(i) * golden.dt
            let amplitude = t < 60 ? 1.0 : max(0, 1 - (t - 60) / 20)
            XCTAssertEqual(fp.update(dt: golden.dt, amplitude: amplitude), expected,
                           accuracy: 1e-3, "fingerprint at tick \(i)")
        }
    }

    func testRewardMatchesTrace() {
        let me = golden.reward.me
        let reward = RewardState(id: me.id, role: me.role, pitchHz: me.pitchHz,
                                 params: params, scale: scale)
        let peer2 = golden.reward.peer2PitchHz
        for (i, tick) in golden.reward.trace.enumerated() {
            let t = Double(i) * golden.dt
            // must mirror simulator/tests/gen_fixtures.mjs scenario() exactly
            let p1near = (t >= 10 && t < 90) || t >= 120
            let p1enc = (t >= 12 && t < 92) || t >= 122
            let p2near = t >= 70 && t < 90
            let p2enc = t >= 72 && t < 92
            let motion = t < 40 ? 0.6 : t < 70 ? 0.0 : t < 90 ? 0.5 : 0.2
            let bloomMultiplier = t >= 120 ? 0.3 : 1.0
            let out = reward.update(dt: golden.dt, RewardInputs(
                encounters: [1: p1enc, 2: p2enc],
                buckets: [1: p1near ? .near : .far, 2: p2near ? .near : .far],
                motion: motion,
                peerPitches: [1: 220, 2: peer2],
                bloomMultiplier: bloomMultiplier))
            XCTAssertEqual(out.W, tick.W, accuracy: 1e-3, "W at \(i)")
            XCTAssertEqual(out.B, tick.B, accuracy: 1e-3, "B at \(i)")
            XCTAssertEqual(out.E, tick.E, accuracy: 1e-3, "E at \(i)")
            XCTAssertEqual(out.F, tick.F, accuracy: 1e-3, "F at \(i)")
            XCTAssertEqual(out.novelty, tick.novelty, accuracy: 1e-3, "novelty at \(i)")
            XCTAssertEqual(out.detuneCents, tick.detune, accuracy: 1e-3, "detune at \(i)")
            XCTAssertEqual(out.partialGains[1], tick.g2, accuracy: 1e-3, "g2 at \(i)")
            XCTAssertEqual(out.partialGains[2], tick.g3, accuracy: 1e-3, "g3 at \(i)")
            XCTAssertEqual(out.focusId ?? -1, tick.focusId, "focus at \(i)")
        }
    }
}
