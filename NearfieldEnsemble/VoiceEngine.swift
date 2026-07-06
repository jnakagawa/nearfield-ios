import AVFoundation

// The phone's voice (spec §6.2): an AVAudioSourceNode rendering the ≤4-partial
// sine stack through the §5.5 voicing — tone shaping (EQ) + generated-IR
// convolution reverb (ConvolutionReverb, the simulator's room). The dry/wet
// split lives inside the render callback; the EQ sits after and applies to
// both paths, which commutes with the simulator's EQ-before-split order
// (all LTI). Frequencies/gains are set from the assignment; per-render-block
// gain smoothing avoids zipper noise.
final class VoiceEngine: ObservableObject {
    @Published private(set) var isPlaying = false

    private let engine = AVAudioEngine()
    private var srcNode: AVAudioSourceNode?
    private let eq = AVAudioUnitEQ(numberOfBands: 2)
    private var convolver: ConvolutionReverb?
    private var dryMix: Float = 1
    private var wetMix: Float = 0
    private var timbre: Params.Timbre?

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
        }
        timbre = t
        // equal-power crossfade, matching the simulator's dry/wet gains
        let wet = (t?.reverbWet ?? 0.3) * .pi / 2
        dryMix = Float(cos(wet))
        wetMix = Float(sin(wet))
    }

    /// 5 Hz from the Conductor: bloom gains, detune (slew + fingerprint), AM.
    func applyReward(_ out: RewardOutputs, extraCents: Double) {
        lastCents = out.detuneCents + extraCents
        let bend = pow(2.0, lastCents / 1200.0)
        for k in 0..<4 {
            freqs[k] = basePitch * (k < ratios.count ? ratios[k] : 1) * bend
            targetGains[k] = out.partialGains[k] * tilt[k]
        }
        amRate = out.amRate
        amDepth = out.amDepth
    }
    private var lastCents = 0.0

    /// Tuning drift (§13.1): the scale ages during the piece; pitch glides.
    func setTuning(pitchHz: Double, ratios newRatios: [Double]) {
        basePitch = pitchHz
        ratios = newRatios
        let bend = pow(2.0, lastCents / 1200.0)
        for k in 0..<4 {
            freqs[k] = basePitch * (k < ratios.count ? ratios[k] : 1) * bend
        }
    }

    /// Whole-voice envelope: breath × anchor swell × master fade × entry gate.
    func setEnvelope(level: Double) {
        voiceLevelTarget = max(level, 0)
    }
    private var voiceLevelTarget = 1.0
    private var voiceLevel = 1.0

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

        // §5.5 generated IR: built once before the engine starts (the render
        // thread reads it immutably; no live rebuild — reverb params are not
        // score-patched)
        convolver = ConvolutionReverb(ir: ConvolutionReverb.generateIR(
            decayS: timbre?.reverbDecayS ?? 5.5,
            dampHz: timbre?.reverbDampHz ?? 3000,
            sampleRate: sampleRate))

        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let twoPi = 2.0 * Double.pi
            // per-block gain glide (~10 ms time constant at 48 kHz blocks)
            for k in 0..<4 {
                self.currentGains[k] += (self.targetGains[k] - self.currentGains[k]) * 0.15
            }
            self.voiceLevel += (self.voiceLevelTarget - self.voiceLevel) * 0.08
            let amInc = twoPi * self.amRate / self.sampleRate
            let conv = self.convolver
            let dryMix = self.dryMix, wetMix = self.wetMix
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
                let value = Float(sample * am * 0.2 * self.voiceLevel)
                let wet = conv?.processSample(value) ?? 0
                let mixed = dryMix * value + wetMix * wet
                for buffer in ablPointer {
                    let buf = UnsafeMutableBufferPointer<Float>(buffer)
                    buf[frame] = mixed
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

        engine.attach(node)
        engine.attach(eq)
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        engine.connect(node, to: eq, format: mono)
        engine.connect(eq, to: engine.mainMixerNode, format: mono)
        try engine.start()
        isPlaying = true
    }

    func setMuted(_ muted: Bool) {
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
        isPlaying = !muted
    }
}
