import XCTest
@testable import NearfieldEnsemble

// Spec §8: a fresh install with no reachable hub must still sing. The solo
// assignment comes from configs bundled in the app itself.
final class SoloFallbackTests: XCTestCase {
    func testBundledConfigsLoad() {
        let cfg = SoloFallback.loadBundledConfigs()
        XCTAssertNotNil(cfg, "scale.json/params.json must ship in the app bundle")
        XCTAssertEqual(cfg?.scale.pseudoOctaveRatio, 2.07)
    }

    func testSoloAssignmentIsADeterministicVoice() {
        let a = SoloFallback.assignment(deviceId: "test-device-123")
        let b = SoloFallback.assignment(deviceId: "test-device-123")
        let c = SoloFallback.assignment(deviceId: "another-device")
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.participantId, b?.participantId)
        XCTAssertEqual(a?.performanceId, b?.performanceId)
        XCTAssertEqual(a?.role, "voice", "solo phones never self-appoint as anchor/shimmer")
        XCTAssertTrue((2...4).contains(a!.participantId))
        XCTAssertNil(a?.score)
        // the assignment matches the deterministic join-order function, so a
        // second hubless phone derives this phone's pitch from its id alone
        let expected = assignmentFor(index: a!.participantId, scale: a!.scale, params: a!.params)
        XCTAssertEqual(a!.pitchHz, expected.pitchHz, accuracy: 1e-9)
        _ = c // distinct devices may or may not collide (3 slots); just must not crash
    }
}
