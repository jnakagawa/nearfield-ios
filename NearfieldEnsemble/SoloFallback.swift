import Foundation

// Spec §8 taken to its conclusion: the piece must be musically complete with
// zero infrastructure. If no hub answers within the grace window, the phone
// assigns ITSELF a voice from the bundled configs — seeded by device id, so
// two hubless phones in one room still form a consonant pair (BLE encounters
// need no server; peers' pitches derive from ids). A real hub assignment
// replaces the solo one seamlessly whenever a connection succeeds.
enum SoloFallback {
    static let graceS: TimeInterval = 8

    static func loadBundledConfigs() -> (scale: Scale, params: Params)? {
        guard
            let sUrl = Bundle.main.url(forResource: "scale", withExtension: "json"),
            let pUrl = Bundle.main.url(forResource: "params", withExtension: "json"),
            let sData = try? Data(contentsOf: sUrl),
            let pData = try? Data(contentsOf: pUrl),
            let scale = try? JSONDecoder().decode(Scale.self, from: sData),
            let params = try? JSONDecoder().decode(Params.self, from: pData)
        else { return nil }
        return (scale, params)
    }

    /// Deterministic per-device voice. Indices 2–4 of the join order are all
    /// "voice" — a solo phone never self-appoints as an anchor or shimmer.
    static func assignment(deviceId: String) -> AssignMessage? {
        guard let (scale, params) = loadBundledConfigs() else { return nil }
        let h = fnv1a(deviceId + "|solo")
        let index = 2 + Int(h % 3)
        let a = assignmentFor(index: index, scale: scale, params: params)
        return AssignMessage(
            type: "assign",
            participantId: index,
            role: a.role,
            degreeIndex: index % scale.scaleCents.count,
            register: 0,
            pitchHz: a.pitchHz,
            scale: scale,
            scaleDrift: nil,
            score: nil,
            params: params,
            performanceId: Int(h))
    }
}
