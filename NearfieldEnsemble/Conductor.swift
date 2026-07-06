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

    static let tickS = 0.2
    private let debugPeerId = 5 // a voice-role id: consonant with most degrees

    func start(assignment a: AssignMessage, voice: VoiceEngine, hub: HubClient) {
        self.voice = voice
        self.hub = hub
        params = a.params
        scale = a.scale
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
        guard let reward, let fingerprint, let params, let scale else { return }
        let dt = Self.tickS

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
            motion: motion, peerPitches: peerPitches))
        let fp = fingerprint.update(dt: dt, amplitude: params.drift.fingerprintAmplitude)
        lastOut = out
        fpCents = fp
        voice?.applyReward(out, extraCents: fp)

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
