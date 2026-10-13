import Accelerate
import Foundation

/// Shared radix-2 FFT setups; vDSP setups are read-only and safe to share.
nonisolated enum DSPFFTSetups {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var setups: [Int: FFTSetupD] = [:]

    static func setup(log2n: Int) -> FFTSetupD? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = setups[log2n] { return existing }
        guard let created = vDSP_create_fftsetupD(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return nil }
        setups[log2n] = created
        return created
    }
}

/// Impulse responses already transformed into partition spectra. Immutable
/// and shared by every engine that convolves with the same responses.
nonisolated final class DSPConvolutionSpectra: @unchecked Sendable {
    struct Partitioning {
        let blockSize: Int
        let offset: Int
        let partitionCount: Int
    }

    let headPartitioning: Partitioning
    let tailPartitioning: Partitioning?
    let pathCount: Int
    /// Split spectra, path-major then partition-major, `blockSize` bins each
    /// (bin 0 packs DC in the real part and Nyquist in the imaginary part).
    fileprivate let headReal: UnsafeMutablePointer<Double>
    fileprivate let headImaginary: UnsafeMutablePointer<Double>
    fileprivate let tailReal: UnsafeMutablePointer<Double>?
    fileprivate let tailImaginary: UnsafeMutablePointer<Double>?

    static let headBlockSize = 256
    static let tailBlockSize = 4_096

    /// - Parameter responses: one impulse response per convolution path.
    init?(responses: [[Double]]) {
        guard !responses.isEmpty, let longest = responses.map(\.count).max(), longest > 0 else { return nil }
        pathCount = responses.count
        let headBlock = Self.headBlockSize
        let tailBlock = Self.tailBlockSize
        let headLength = min(longest, tailBlock)
        headPartitioning = Partitioning(blockSize: headBlock, offset: 0,
                                        partitionCount: (headLength + headBlock - 1) / headBlock)
        if longest > tailBlock {
            tailPartitioning = Partitioning(blockSize: tailBlock, offset: tailBlock,
                                            partitionCount: (longest - tailBlock + tailBlock - 1) / tailBlock)
        } else {
            tailPartitioning = nil
        }
        let headCount = pathCount * headPartitioning.partitionCount * headBlock
        headReal = .allocate(capacity: headCount)
        headImaginary = .allocate(capacity: headCount)
        if let tail = tailPartitioning {
            let count = pathCount * tail.partitionCount * tailBlock
            tailReal = .allocate(capacity: count)
            tailImaginary = .allocate(capacity: count)
        } else {
            tailReal = nil
            tailImaginary = nil
        }
        guard Self.transform(responses, partitioning: headPartitioning, real: headReal, imaginary: headImaginary) else {
            return nil
        }
        if let tail = tailPartitioning, let tailReal, let tailImaginary {
            guard Self.transform(responses, partitioning: tail, real: tailReal, imaginary: tailImaginary) else {
                return nil
            }
        }
    }

    deinit {
        headReal.deallocate()
        headImaginary.deallocate()
        tailReal?.deallocate()
        tailImaginary?.deallocate()
    }

    var byteCount: Int {
        let head = pathCount * headPartitioning.partitionCount * headPartitioning.blockSize
        let tail = pathCount * (tailPartitioning.map { $0.partitionCount * $0.blockSize } ?? 0)
        return (head + tail) * 16
    }

    /// Zero-padded partitions, forward transformed and pre-scaled so the
    /// product's inverse transform needs no further scaling.
    private static func transform(
        _ responses: [[Double]],
        partitioning: Partitioning,
        real: UnsafeMutablePointer<Double>,
        imaginary: UnsafeMutablePointer<Double>
    ) -> Bool {
        let block = partitioning.blockSize
        let size = block * 2
        let log2n = Int(log2(Double(size)).rounded())
        guard let setup = DSPFFTSetups.setup(log2n: log2n),
              let scale = DSPConvolutionLevel.productScale(setup: setup, log2n: log2n) else { return false }
        var frame = [Double](repeating: 0, count: size)
        for (path, response) in responses.enumerated() {
            for partition in 0..<partitioning.partitionCount {
                for index in frame.indices { frame[index] = 0 }
                let start = partitioning.offset + partition * block
                if start < response.count {
                    let end = min(response.count, start + block)
                    for index in start..<end { frame[index - start] = response[index] * scale }
                }
                let base = (path * partitioning.partitionCount + partition) * block
                var split = DSPDoubleSplitComplex(realp: real + base, imagp: imaginary + base)
                frame.withUnsafeBufferPointer { time in
                    time.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: block) { complex in
                        vDSP_ctozD(complex, 2, &split, 1, vDSP_Length(block))
                    }
                }
                vDSP_fft_zripD(setup, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
            }
        }
        return true
    }
}

/// One uniformly partitioned overlap-save stage: an input frame history,
/// the frequency-domain delay line of past input spectra and an output
/// accumulator per output channel.
nonisolated final class DSPConvolutionLevel {
    let blockSize: Int
    let partitionCount: Int
    private let log2n: Int
    private let setup: FFTSetupD
    private let inputCount: Int
    private let outputCount: Int
    /// [input][2 × block]: previous block then the block being filled.
    let frames: UnsafeMutablePointer<Double>
    private let delayReal: UnsafeMutablePointer<Double>
    private let delayImaginary: UnsafeMutablePointer<Double>
    private var delayCursor = 0
    private let accumulatorReal: UnsafeMutablePointer<Double>
    private let accumulatorImaginary: UnsafeMutablePointer<Double>
    private let timeScratch: UnsafeMutablePointer<Double>
    /// [output][block]: the newest output block.
    let output: UnsafeMutablePointer<Double>

    init?(blockSize: Int, partitionCount: Int, inputCount: Int, outputCount: Int) {
        let size = blockSize * 2
        let log2n = Int(log2(Double(size)).rounded())
        guard 1 << log2n == size, let setup = DSPFFTSetups.setup(log2n: log2n) else { return nil }
        self.blockSize = blockSize
        self.partitionCount = partitionCount
        self.log2n = log2n
        self.setup = setup
        self.inputCount = inputCount
        self.outputCount = outputCount
        frames = .allocate(capacity: inputCount * size)
        delayReal = .allocate(capacity: inputCount * partitionCount * blockSize)
        delayImaginary = .allocate(capacity: inputCount * partitionCount * blockSize)
        accumulatorReal = .allocate(capacity: blockSize)
        accumulatorImaginary = .allocate(capacity: blockSize)
        timeScratch = .allocate(capacity: size)
        output = .allocate(capacity: outputCount * blockSize)
        reset()
    }

    deinit {
        frames.deallocate()
        delayReal.deallocate()
        delayImaginary.deallocate()
        accumulatorReal.deallocate()
        accumulatorImaginary.deallocate()
        timeScratch.deallocate()
        output.deallocate()
    }

    var byteCount: Int { (inputCount * (2 * blockSize + 2 * partitionCount * blockSize) + outputCount * blockSize) * 8 }

    func reset() {
        frames.update(repeating: 0, count: inputCount * blockSize * 2)
        delayReal.update(repeating: 0, count: inputCount * partitionCount * blockSize)
        delayImaginary.update(repeating: 0, count: inputCount * partitionCount * blockSize)
        output.update(repeating: 0, count: outputCount * blockSize)
        delayCursor = 0
    }

    /// Copies input history by age, so a stage with more or fewer
    /// partitions (a longer or shorter response) continues seamlessly.
    func copyState(from source: DSPConvolutionLevel) {
        guard source.blockSize == blockSize, source.inputCount == inputCount,
              source.outputCount == outputCount else { return }
        frames.update(from: source.frames, count: inputCount * blockSize * 2)
        output.update(from: source.output, count: outputCount * blockSize)
        if source.partitionCount == partitionCount {
            delayReal.update(from: source.delayReal, count: inputCount * partitionCount * blockSize)
            delayImaginary.update(from: source.delayImaginary, count: inputCount * partitionCount * blockSize)
            delayCursor = source.delayCursor
            return
        }
        delayReal.update(repeating: 0, count: inputCount * partitionCount * blockSize)
        delayImaginary.update(repeating: 0, count: inputCount * partitionCount * blockSize)
        delayCursor = 0
        // Age k is the k-th most recent spectrum, stored just behind the cursor.
        for age in 1...min(source.partitionCount, partitionCount) {
            let from = (source.delayCursor - age + source.partitionCount * 2) % source.partitionCount
            let to = (partitionCount * 2 - age) % partitionCount
            for input in 0..<inputCount {
                let sourceBase = (input * source.partitionCount + from) * blockSize
                let targetBase = (input * partitionCount + to) * blockSize
                (delayReal + targetBase).update(from: source.delayReal + sourceBase, count: blockSize)
                (delayImaginary + targetBase).update(from: source.delayImaginary + sourceBase, count: blockSize)
            }
        }
    }

    /// Transforms the completed input block, convolves it with every path
    /// and writes one new output block per output channel.
    func compute(
        real spectraReal: UnsafeMutablePointer<Double>,
        imaginary spectraImaginary: UnsafeMutablePointer<Double>,
        routes: [DSPConvolutionEngine.Route]
    ) {
        let block = blockSize
        let size = block * 2
        // Newest input spectrum into the delay line.
        for input in 0..<inputCount {
            let frame = frames + input * size
            let base = (input * partitionCount + delayCursor) * block
            var split = DSPDoubleSplitComplex(realp: delayReal + base, imagp: delayImaginary + base)
            frame.withMemoryRebound(to: DSPDoubleComplex.self, capacity: block) { complex in
                vDSP_ctozD(complex, 2, &split, 1, vDSP_Length(block))
            }
            vDSP_fft_zripD(setup, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
            // The block just finished becomes the previous half.
            frame.update(from: frame + block, count: block)
        }

        for output in 0..<outputCount {
            accumulatorReal.update(repeating: 0, count: block)
            accumulatorImaginary.update(repeating: 0, count: block)
            var accumulator = DSPDoubleSplitComplex(realp: accumulatorReal, imagp: accumulatorImaginary)
            // vDSP accumulates in place; the addend and result describe the
            // same memory through two descriptors.
            var addend = DSPDoubleSplitComplex(realp: accumulatorReal + 1, imagp: accumulatorImaginary + 1)
            var sum = DSPDoubleSplitComplex(realp: accumulatorReal + 1, imagp: accumulatorImaginary + 1)
            for route in routes where route.output == output {
                for partition in 0..<partitionCount {
                    var slot = delayCursor - partition
                    if slot < 0 { slot += partitionCount }
                    let x = (route.input * partitionCount + slot) * block
                    let h = (route.path * partitionCount + partition) * block
                    // Bin 0 packs two real values; multiply them separately.
                    accumulatorReal[0] += delayReal[x] * spectraReal[h]
                    accumulatorImaginary[0] += delayImaginary[x] * spectraImaginary[h]
                    var a = DSPDoubleSplitComplex(realp: delayReal + x + 1, imagp: delayImaginary + x + 1)
                    var b = DSPDoubleSplitComplex(realp: spectraReal + h + 1, imagp: spectraImaginary + h + 1)
                    vDSP_zvmaD(&a, 1, &b, 1, &addend, 1, &sum, 1, vDSP_Length(block - 1))
                }
            }
            vDSP_fft_zripD(setup, &accumulator, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Inverse))
            timeScratch.withMemoryRebound(to: DSPDoubleComplex.self, capacity: block) { complex in
                vDSP_ztocD(&accumulator, 1, complex, 2, vDSP_Length(block))
            }
            // Overlap-save keeps the second half.
            (self.output + output * block).update(from: timeScratch + block, count: block)
        }
        delayCursor = (delayCursor + 1) % partitionCount
    }

    /// Scale that turns zrip-forward(x) · zrip-forward(h), inverse
    /// transformed, into x ⊛ h. Measured on the setup itself instead of
    /// assumed from documentation.
    static func productScale(setup: FFTSetupD, log2n: Int) -> Double? {
        let size = 1 << log2n
        let half = size / 2
        var time = [Double](repeating: 0, count: size)
        time[1] = 1
        var real = [Double](repeating: 0, count: half)
        var imaginary = [Double](repeating: 0, count: half)
        var roundTrip = 0.0
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPDoubleSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                time.withUnsafeMutableBufferPointer { timeBuffer in
                    timeBuffer.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) { complex in
                        vDSP_ctozD(complex, 2, &split, 1, vDSP_Length(half))
                        vDSP_fft_zripD(setup, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
                        vDSP_fft_zripD(setup, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Inverse))
                        vDSP_ztocD(&split, 1, complex, 2, vDSP_Length(half))
                    }
                }
                roundTrip = time[1]
            }
        }
        // A product of two forward spectra carries one forward factor more
        // than a round trip: forward(δ) is 2 in every bin.
        guard roundTrip.isFinite, roundTrip != 0 else { return nil }
        return 1 / (2 * roundTrip)
    }
}

/// Multichannel convolution with one 256-frame block of latency, after
/// Gardner's non-uniform partitioning (JAES 1995): a 256-point head stage
/// covers the first 4096 taps and 4096-point tail partitions cover the
/// rest. The tail stage computes once per 4096 frames; its result is due
/// exactly when the head stage reaches it. The processor's run-ahead
/// compensates the head block, so the output stays time-aligned.
nonisolated final class DSPConvolutionEngine: @unchecked Sendable {
    struct Route: Equatable, Sendable {
        let input: Int
        let output: Int
        let path: Int
    }

    let spectra: DSPConvolutionSpectra
    let routes: [Route]
    let inputCount: Int
    let outputCount: Int
    private let head: DSPConvolutionLevel
    private let tail: DSPConvolutionLevel?
    /// [output][2 × tail block]: tail segment being consumed, then the next.
    private let tailSegments: UnsafeMutablePointer<Double>?
    private var headFill = 0
    private var tailFill = 0
    private var tailReadPosition = 0
    private var currentTailSegment = 0
    /// Frames processed, modulo the tail block: aligns a tail stage that
    /// appears when a longer response takes over.
    private var position = 0

    var latencyFrames: Int { spectra.headPartitioning.blockSize }

    init?(spectra: DSPConvolutionSpectra, routes: [Route], inputCount: Int, outputCount: Int) {
        guard routes.allSatisfy({ $0.path < spectra.pathCount && $0.input < inputCount && $0.output < outputCount }),
              let head = DSPConvolutionLevel(
                blockSize: spectra.headPartitioning.blockSize,
                partitionCount: spectra.headPartitioning.partitionCount,
                inputCount: inputCount, outputCount: outputCount) else { return nil }
        self.spectra = spectra
        self.routes = routes
        self.inputCount = inputCount
        self.outputCount = outputCount
        self.head = head
        if let partitioning = spectra.tailPartitioning {
            guard let tail = DSPConvolutionLevel(blockSize: partitioning.blockSize,
                                                 partitionCount: partitioning.partitionCount,
                                                 inputCount: inputCount, outputCount: outputCount) else { return nil }
            self.tail = tail
            let segments = UnsafeMutablePointer<Double>.allocate(capacity: outputCount * partitioning.blockSize * 2)
            segments.update(repeating: 0, count: outputCount * partitioning.blockSize * 2)
            tailSegments = segments
        } else {
            tail = nil
            tailSegments = nil
        }
    }

    deinit {
        tailSegments?.deallocate()
        io.deallocate()
    }

    /// Two inputs and two outputs, the stereo case, without caller buffers.
    private let io: UnsafeMutablePointer<Double> = .allocate(capacity: 4)

    @inline(__always)
    func processStereo(_ left: Double, _ right: Double) -> (left: Double, right: Double) {
        io[0] = left
        io[1] = right
        process(inputs: io, outputs: io + 2)
        return (io[2], io[3])
    }

    /// A new engine on the same responses with silent state.
    func makeFresh() -> DSPConvolutionEngine? {
        DSPConvolutionEngine(spectra: spectra, routes: routes, inputCount: inputCount, outputCount: outputCount)
    }

    var stateBytes: Int {
        head.byteCount + (tail?.byteCount ?? 0)
            + (tail.map { outputCount * $0.blockSize * 2 * 8 } ?? 0)
    }

    /// Input history carries over even when the responses differ, so a new
    /// room or distance takes over without a gap.
    func copyState(from source: DSPConvolutionEngine) {
        guard source.inputCount == inputCount, source.outputCount == outputCount else { return }
        head.copyState(from: source.head)
        headFill = source.headFill
        position = source.position
        if let tail, let other = source.tail, let tailSegments, let otherSegments = source.tailSegments {
            tail.copyState(from: other)
            tailSegments.update(from: otherSegments, count: outputCount * tail.blockSize * 2)
            tailFill = source.tailFill
            tailReadPosition = source.tailReadPosition
            currentTailSegment = source.currentTailSegment
        } else if let tail {
            // A tail stage the source lacked starts silent, aligned to the
            // running position; it fills within one tail block.
            tailFill = position % tail.blockSize
            tailReadPosition = (position - headFill) % tail.blockSize
            currentTailSegment = 0
        }
    }

    func reset() {
        head.reset()
        tail?.reset()
        if let tail, let tailSegments {
            tailSegments.update(repeating: 0, count: outputCount * tail.blockSize * 2)
        }
        headFill = 0
        tailFill = 0
        tailReadPosition = 0
        currentTailSegment = 0
        position = 0
    }

    /// Convolves one frame. `inputs` and `outputs` hold one value per channel.
    @inline(__always)
    func process(inputs: UnsafePointer<Double>, outputs: UnsafeMutablePointer<Double>) {
        let headBlock = head.blockSize
        let headFrameSize = headBlock * 2
        for input in 0..<inputCount {
            head.frames[input * headFrameSize + headBlock + headFill] = inputs[input]
        }
        for output in 0..<outputCount {
            outputs[output] = head.output[output * headBlock + headFill]
        }
        if let tail {
            let tailBlock = tail.blockSize
            for input in 0..<inputCount {
                tail.frames[input * tailBlock * 2 + tailBlock + tailFill] = inputs[input]
            }
            tailFill += 1
            if tailFill == tailBlock {
                tailFill = 0
                tail.compute(real: spectra.tailReal!, imaginary: spectra.tailImaginary!, routes: routes)
                // The fresh segment covers the next tail block of output.
                let next = 1 - currentTailSegment
                for output in 0..<outputCount {
                    (tailSegments! + (output * 2 + next) * tailBlock)
                        .update(from: tail.output + output * tailBlock, count: tailBlock)
                }
            }
        }
        position = position + 1 == DSPConvolutionSpectra.tailBlockSize ? 0 : position + 1
        headFill += 1
        if headFill == headBlock {
            headFill = 0
            head.compute(real: spectra.headReal, imaginary: spectra.headImaginary, routes: routes)
            if let tail, let tailSegments {
                let tailBlock = tail.blockSize
                for output in 0..<outputCount {
                    let segment = tailSegments + (output * 2 + currentTailSegment) * tailBlock + tailReadPosition
                    let destination = head.output + output * headBlock
                    vDSP_vaddD(destination, 1, segment, 1, destination, 1, vDSP_Length(headBlock))
                }
                tailReadPosition += headBlock
                if tailReadPosition == tailBlock {
                    tailReadPosition = 0
                    currentTailSegment = 1 - currentTailSegment
                }
            }
        }
    }
}
