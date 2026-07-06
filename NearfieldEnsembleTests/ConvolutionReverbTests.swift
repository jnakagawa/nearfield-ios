import XCTest
@testable import NearfieldEnsemble

// §5.5 convolution reverb: the FFT engine must be an exact convolver (the
// character of the room is entirely in the generated IR), and the IR
// generator must be deterministic — it is the simulator's rebuildReverbIR.
final class ConvolutionReverbTests: XCTestCase {

    // A delta IR makes the convolver a pure delay of one partition.
    func testDeltaIRPassesThroughWithLatency() {
        var ir = [Float](repeating: 0, count: 10)
        ir[0] = 1
        let conv = ConvolutionReverb(ir: ir, partition: 64)
        var rng = Mulberry32(seed: 7)
        let x = (0..<500).map { _ in Float(rng.next() * 2 - 1) }
        var out: [Float] = []
        for v in x { out.append(conv.processSample(v)) }
        for _ in 0..<64 { out.append(conv.processSample(0)) }
        for n in 0..<64 { XCTAssertEqual(out[n], 0, accuracy: 1e-6) }
        for n in 0..<500 { XCTAssertEqual(out[n + 64], x[n], accuracy: 1e-4) }
    }

    // Partitioned-FFT output must match direct time-domain convolution,
    // including across partition boundaries (IR longer than one partition).
    func testMatchesDirectConvolution() {
        var rng = Mulberry32(seed: 42)
        let ir = (0..<300).map { _ in Float(rng.next() * 2 - 1) }
        let x = (0..<1000).map { _ in Float(rng.next() * 2 - 1) }
        var direct = [Float](repeating: 0, count: 1000)
        for n in 0..<1000 {
            var acc: Float = 0
            for k in 0..<min(n + 1, 300) { acc += ir[k] * x[n - k] }
            direct[n] = acc
        }
        let conv = ConvolutionReverb(ir: ir, partition: 128)
        var out: [Float] = []
        for v in x { out.append(conv.processSample(v)) }
        for _ in 0..<128 { out.append(conv.processSample(0)) }
        for n in 0..<1000 {
            XCTAssertEqual(out[n + 128], direct[n], accuracy: 5e-3)
        }
    }

    func testGeneratedIRDeterministicAndDecaying() {
        let a = ConvolutionReverb.generateIR(decayS: 2, dampHz: 3000, sampleRate: 48_000)
        let b = ConvolutionReverb.generateIR(decayS: 2, dampHz: 3000, sampleRate: 48_000)
        XCTAssertEqual(a.count, 96_000)
        XCTAssertEqual(a, b)
        func rms(_ s: ArraySlice<Float>) -> Float {
            sqrt(s.reduce(0) { $0 + $1 * $1 } / Float(s.count))
        }
        // exp(-6.9·i/len) is ~RT60 across the buffer: the head must tower
        // over the tail (envelope ratio head/tail decade ≈ 360×)
        XCTAssertGreaterThan(rms(a[0..<9_600]), rms(a[86_400...]) * 20)
    }
}
