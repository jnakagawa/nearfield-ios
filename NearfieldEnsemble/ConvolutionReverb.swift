import Accelerate
import Foundation

// §5.5 generated-IR convolution reverb — replaces the AVAudioUnitReverb
// stand-in. The IR is the simulator's rebuildReverbIR() ported exactly
// (mulberry32(1234) damped noise under an exponential ~RT60 envelope), so
// both renderers share one room. Rendering is uniform partitioned FFT
// convolution (overlap-add) on vDSP; the wet path carries one partition of
// latency (~21 ms at 48 kHz with the default partition), which reads as
// pre-delay. All memory is allocated in init — the render thread only does
// vDSP work.
final class ConvolutionReverb {
    private let partition: Int
    private let fftSize: Int          // 2 * partition
    private let bins: Int             // partition + 1, unpacked spectrum
    private let log2n: vDSP_Length
    private let numPartitions: Int
    private let fft: FFTSetup

    // flat [numPartitions * bins] unpacked split-complex spectra
    private let irRe, irIm: UnsafeMutablePointer<Float>   // IR partitions (pre-scaled)
    private let inRe, inIm: UnsafeMutablePointer<Float>   // ring of past input spectra
    private var ringIdx = 0

    private let accRe, accIm: UnsafeMutablePointer<Float> // bins
    private let pkRe, pkIm: UnsafeMutablePointer<Float>   // partition (packed FFT workspace)
    private let timeBuf: UnsafeMutablePointer<Float>      // fftSize
    private let overlap: UnsafeMutablePointer<Float>      // partition
    private let inBlock: UnsafeMutablePointer<Float>      // partition
    private let outBlock: UnsafeMutablePointer<Float>     // partition
    private var fifoPos = 0

    init(ir: [Float], partition: Int = 1024) {
        precondition(partition > 0 && partition & (partition - 1) == 0,
                     "partition must be a power of two")
        self.partition = partition
        fftSize = 2 * partition
        bins = partition + 1
        log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        numPartitions = max(1, (ir.count + partition - 1) / partition)
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        func alloc(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        irRe = alloc(numPartitions * bins); irIm = alloc(numPartitions * bins)
        inRe = alloc(numPartitions * bins); inIm = alloc(numPartitions * bins)
        accRe = alloc(bins); accIm = alloc(bins)
        pkRe = alloc(partition); pkIm = alloc(partition)
        timeBuf = alloc(fftSize)
        overlap = alloc(partition)
        inBlock = alloc(partition)
        outBlock = alloc(partition)

        // Precompute IR partition spectra. vDSP_fft_zrip forward = 2×DFT and
        // its inverse is the unnormalized transpose, so a forward·forward·
        // inverse convolution comes out 4N too big — fold 1/(4N) in here.
        let scale = Float(1) / (4 * Float(fftSize))
        for j in 0..<numPartitions {
            for i in 0..<fftSize { timeBuf[i] = 0 }
            let base = j * partition
            for i in 0..<min(partition, ir.count - base) {
                timeBuf[i] = ir[base + i] * scale
            }
            forwardFFT(into: irRe + j * bins, irIm + j * bins)
        }
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
        for p in [irRe, irIm, inRe, inIm, accRe, accIm, pkRe, pkIm,
                  timeBuf, overlap, inBlock, outBlock] { p.deallocate() }
    }

    /// One sample in, one wet sample out (delayed by `partition` samples).
    func processSample(_ x: Float) -> Float {
        inBlock[fifoPos] = x
        let out = outBlock[fifoPos]
        fifoPos += 1
        if fifoPos == partition {
            processBlock()
            fifoPos = 0
        }
        return out
    }

    private func processBlock() {
        // spectrum of the current block (zero-padded to fftSize)
        for i in 0..<partition { timeBuf[i] = inBlock[i] }
        for i in partition..<fftSize { timeBuf[i] = 0 }
        forwardFFT(into: inRe + ringIdx * bins, inIm + ringIdx * bins)

        // acc = Σ_j input[k−j] · IR[j]
        vDSP_vclr(accRe, 1, vDSP_Length(bins))
        vDSP_vclr(accIm, 1, vDSP_Length(bins))
        var acc = DSPSplitComplex(realp: accRe, imagp: accIm)
        for j in 0..<numPartitions {
            let idx = (ringIdx - j + numPartitions) % numPartitions
            var a = DSPSplitComplex(realp: inRe + idx * bins, imagp: inIm + idx * bins)
            var b = DSPSplitComplex(realp: irRe + j * bins, imagp: irIm + j * bins)
            vDSP_zvma(&a, 1, &b, 1, &acc, 1, &acc, 1, vDSP_Length(bins))
        }
        ringIdx = (ringIdx + 1) % numPartitions

        // repack (DC/Nyquist into element 0) and inverse FFT
        pkRe[0] = accRe[0]
        pkIm[0] = accRe[partition]
        for k in 1..<partition { pkRe[k] = accRe[k]; pkIm[k] = accIm[k] }
        var split = DSPSplitComplex(realp: pkRe, imagp: pkIm)
        vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_INVERSE))
        UnsafeMutableRawPointer(timeBuf).withMemoryRebound(
            to: DSPComplex.self, capacity: partition
        ) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(partition)) }

        // overlap-add
        vDSP_vadd(timeBuf, 1, overlap, 1, outBlock, 1, vDSP_Length(partition))
        overlap.update(from: timeBuf + partition, count: partition)
    }

    /// Packed real forward FFT of `timeBuf`, unpacked to `bins` split-complex.
    private func forwardFFT(into re: UnsafeMutablePointer<Float>,
                            _ im: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: pkRe, imagp: pkIm)
        UnsafeRawPointer(timeBuf).withMemoryRebound(
            to: DSPComplex.self, capacity: partition
        ) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(partition)) }
        vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        re[0] = pkRe[0]; im[0] = 0
        re[partition] = pkIm[0]; im[partition] = 0
        for k in 1..<partition { re[k] = pkRe[k]; im[k] = pkIm[k] }
    }

    /// The simulator's rebuildReverbIR(), mono (its channel-0 sequence):
    /// mulberry32(1234) noise through a one-pole lowpass at `dampHz`, under
    /// exp(−6.9·i/len) (~RT60 across the buffer). Normalized like WebAudio's
    /// ConvolverNode normalize:true (−58 dB calibration at 50 kHz reference)
    /// so the wet level lands where the simulator's does.
    static func generateIR(decayS: Double, dampHz: Double, sampleRate: Double) -> [Float] {
        let len = max(1, Int(decayS * sampleRate))
        var rng = Mulberry32(seed: 1234)
        let dampA = 1 - exp(-2 * .pi * dampHz / sampleRate)
        var ir = [Float](repeating: 0, count: len)
        var lp = 0.0
        for i in 0..<len {
            let env = exp(-6.9 * Double(i) / Double(len))
            lp += ((rng.next() * 2 - 1) - lp) * dampA
            ir[i] = Float(lp * env)
        }
        var power: Float = 0
        vDSP_svesq(ir, 1, &power, vDSP_Length(len))
        let rms = sqrt(power / Float(len))
        if rms > 1e-12 {
            var scale = Float(pow(10.0, -58.0 / 20.0) * (50_000 / sampleRate)) / rms
            vDSP_vsmul(ir, 1, &scale, &ir, 1, vDSP_Length(len))
        }
        return ir
    }
}
