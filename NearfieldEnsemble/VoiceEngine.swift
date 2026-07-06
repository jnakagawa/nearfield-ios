import AVFoundation

// The phone's voice (spec §6.2): an AVAudioSourceNode rendering the ≤4-partial
// sine stack, into tone shaping + reverb approximating the §5.5 voicing
// (AVAudioUnitReverb stands in for the generated-IR convolution until the
// Piece phase). Frequencies/gains are set from the assignment; per-render-
// block gain smoothing avoids zipper noise.
final class VoiceEngine: ObservableObject {
    @Published private(set) var isPlaying = false

    private let engine = AVAudioEngine()
    private var srcNode: AVAudioSourceNode?
    private let eq = AVAudioUnitEQ(numberOfBands: 2)
    private let reverb = AVAudioUnitReverb()

    // render-thread state (written from main via setVoice/applyReward/setMuted;
    // aligned 64-bit stores are atomic on arm64 — acceptable for slow control data)
    private var phases = [Double](repeating: 0, count: 4)
    private var freqs = [Double](repeating: 0, count: 4)
    private var targetGains = [Double](repeating: 0, count: 4)
    private var currentGains = [Double](repeating: 0, count: 4)
    private var sampleRate: Double = 48_000
    private var amPhase = 0.0
    private var amRate = 0.1
    private var amDepth = 0.0

    private var basePitch: Double = 220
    private var ratios: [Double] = [1, 2.07, 3.2, 4.4]
    private var tilt = [Double](repeating: 1, count: 4)

    func setVoice(pitchHz: Double, scale: Scale, params: Params, role: String) {
        basePitch = pitchHz
        ratios = scale.spectrum.ratios
        let t = params.timbre
        let refHz = t?.loudnessRefHz ?? 300
        let exp = t?.loudnessExponent ?? 0.5
        for k in 0..<4 {
            let f = pitchHz * (k < ratios.count ? ratios[k] : 1)
            freqs[k] = f
            tilt[k] = min(1.0, pow(refHz / f, exp)) // equal-loudness (§5.5)
        }
        // fundamental sounds immediately; upper partials wait for bloom (§5.3)
        targetGains[0] = tilt[0]
        for k in 1..<4 { targetGains[k] = 0 }
        if let t {
            eq.bands[0].frequency = Float(t.shelfFreqHz)
            eq.bands[0].gain = Float(t.shelfGainDb)
            eq.bands[1].frequency = Float(t.lowpassHz)
            reverb.wetDryMix = Float(t.reverbWet * 100)
        }
    }

    /// 5 Hz from the Conductor: bloom gains, detune (slew + fingerprint), AM.
    func applyReward(_ out: RewardOutputs, extraCents: Double) {
        let cents = out.detuneCents + extraCents
        let bend = pow(2.0, cents / 1200.0)
        for k in 0..<4 {
            freqs[k] = basePitch * (k < ratios.count ? ratios[k] : 1) * bend
            targetGains[k] = out.partialGains[k] * tilt[k]
        }
        amRate = out.amRate
        amDepth = out.amDepth
    }

    func start() throws {
        guard srcNode == nil else {
            engine.mainMixerNode.outputVolume = 1
            isPlaying = true
            return
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)

        let format = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = format.sampleRate

        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let twoPi = 2.0 * Double.pi
            // per-block gain glide (~10 ms time constant at 48 kHz blocks)
            for k in 0..<4 {
                self.currentGains[k] += (self.targetGains[k] - self.currentGains[k]) * 0.15
            }
            let amInc = twoPi * self.amRate / self.sampleRate
            for frame in 0..<Int(frameCount) {
                var sample = 0.0
                for k in 0..<4 where self.currentGains[k] > 1e-5 {
                    sample += self.currentGains[k] * sin(self.phases[k])
                    self.phases[k] += twoPi * self.freqs[k] / self.sampleRate
                    if self.phases[k] > twoPi { self.phases[k] -= twoPi }
                }
                // shimmer AM at audio rate (§5.3), like the simulator's LFO nodes
                self.amPhase += amInc
                if self.amPhase > twoPi { self.amPhase -= twoPi }
                let am = 1.0 + self.amDepth * sin(self.amPhase)
                let value = Float(sample * am * 0.2)
                for buffer in ablPointer {
                    let buf = UnsafeMutableBufferPointer<Float>(buffer)
                    buf[frame] = value
                }
            }
            return noErr
        }
        srcNode = node

        eq.bands[0].filterType = .highShelf
        eq.bands[0].frequency = 1800
        eq.bands[0].gain = -7
        eq.bands[0].bypass = false
        eq.bands[1].filterType = .lowPass
        eq.bands[1].frequency = 4200
        eq.bands[1].bypass = false
        reverb.loadFactoryPreset(.largeHall2)
        reverb.wetDryMix = 30

        engine.attach(node)
        engine.attach(eq)
        engine.attach(reverb)
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        engine.connect(node, to: eq, format: mono)
        engine.connect(eq, to: reverb, format: mono)
        engine.connect(reverb, to: engine.mainMixerNode, format: mono)
        try engine.start()
        isPlaying = true
    }

    func setMuted(_ muted: Bool) {
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
        isPlaying = !muted
    }
}
