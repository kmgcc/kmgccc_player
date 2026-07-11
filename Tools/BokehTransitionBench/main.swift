// Minimal offscreen benchmark for the fullscreen transition gather pass.
// This tool intentionally permits command-buffer waits and readback: it never
// runs in the player process and exists only to establish a local performance
// and visual baseline for the shipped shader.

import Foundation
import Metal

struct TransitionBokehUniforms {
    var radiusAt1080: Float
    var highlightPower: Float
    var highlightThreshold: Float
    var sampleBudget: UInt32
    var apertureBlades: Int32
    var apertureRotationRadians: Float
    var apertureRoundness: Float
    var padding: Float = 0
}

struct BenchmarkCase {
    let width: Int
    let height: Int
    let samples: UInt32
}

enum BenchmarkError: LocalizedError {
    case usage
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .usage: "Usage: BokehTransitionBench <BokehTransitionShader.metallib> [output-directory]"
        case let .unavailable(message): message
        }
    }
}

struct BokehTransitionBench {
    static func run() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else { throw BenchmarkError.usage }
        let metallibURL = URL(fileURLWithPath: arguments[1])
        let outputDirectory = URL(fileURLWithPath: arguments.count >= 3 ? arguments[2] : ".", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw BenchmarkError.unavailable("Metal device or command queue unavailable")
        }
        let library = try device.makeLibrary(URL: metallibURL)
        guard let function = library.makeFunction(name: "basicBokehGather") else {
            throw BenchmarkError.unavailable("basicBokehGather is not in the supplied metallib")
        }
        let pipeline = try device.makeComputePipelineState(function: function)

        let cases: [BenchmarkCase] = [
            .init(width: 960, height: 540, samples: 64),
            .init(width: 960, height: 540, samples: 96),
            .init(width: 960, height: 540, samples: 128),
            .init(width: 960, height: 540, samples: 160),
            .init(width: 960, height: 600, samples: 128),
            .init(width: 1280, height: 360, samples: 128),
            .init(width: 720, height: 720, samples: 128)
        ]

        for benchmark in cases {
            let result = try run(
                benchmark,
                device: device,
                queue: queue,
                pipeline: pipeline,
                outputDirectory: outputDirectory,
                writeImage: benchmark.width == 960 && benchmark.height == 540 && (benchmark.samples == 64 || benchmark.samples == 128)
            )
            print("\(benchmark.width)x\(benchmark.height) / \(benchmark.samples) samples: median \(String(format: "%.2f", result.median * 1_000))ms, P95 \(String(format: "%.2f", result.p95 * 1_000))ms")
        }
    }

    private static func run(
        _ benchmark: BenchmarkCase,
        device: MTLDevice,
        queue: MTLCommandQueue,
        pipeline: MTLComputePipelineState,
        outputDirectory: URL,
        writeImage: Bool
    ) throws -> (median: Double, p95: Double) {
        let input = try makeTexture(
            device: device,
            width: benchmark.width,
            height: benchmark.height,
            pixelFormat: .rgba8Unorm,
            usage: [.shaderRead]
        )
        let output = try makeTexture(
            device: device,
            width: benchmark.width,
            height: benchmark.height,
            pixelFormat: .rgba16Float,
            usage: [.shaderWrite]
        )
        uploadSyntheticHighlights(to: input)
        var uniforms = TransitionBokehUniforms(
            radiusAt1080: 44,
            highlightPower: 3,
            highlightThreshold: 0.70,
            sampleBudget: benchmark.samples,
            apertureBlades: 0,
            apertureRotationRadians: 0,
            apertureRoundness: 0
        )

        var samples: [Double] = []
        for frame in 0..<30 {
            guard let buffer = queue.makeCommandBuffer(),
                  let encoder = buffer.makeComputeCommandEncoder() else {
                throw BenchmarkError.unavailable("Unable to make benchmark command buffer")
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<TransitionBokehUniforms>.stride, index: 0)
            let width = min(16, pipeline.threadExecutionWidth)
            let height = min(16, max(1, pipeline.maxTotalThreadsPerThreadgroup / width))
            encoder.dispatchThreads(
                MTLSize(width: benchmark.width, height: benchmark.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
            )
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            if frame >= 5 {
                samples.append(buffer.gpuEndTime - buffer.gpuStartTime)
            }
        }

        // The app's gather target is linear rgba16Float. Image export is kept
        // disabled here until it passes through the same sRGB present pass as
        // the app; reading half-float bytes as display RGB would be misleading.
        _ = writeImage

        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.95).rounded(.up)))]
        return (median, p95)
    }

    private static func makeTexture(
        device: MTLDevice,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        usage: MTLTextureUsage
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BenchmarkError.unavailable("Unable to allocate \(width)x\(height) texture")
        }
        return texture
    }

    private static func uploadSyntheticHighlights(to texture: MTLTexture) {
        let width = texture.width
        let height = texture.height
        var pixels = [UInt8](repeating: 8, count: width * height * 4)
        let points: [(Double, Double, Double)] = [
            (0.14, 0.22, 1.0), (0.38, 0.66, 0.95), (0.62, 0.31, 1.0),
            (0.81, 0.72, 0.98), (0.52, 0.49, 0.84), (0.25, 0.83, 0.78)
        ]
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width)
                let v = Double(y) / Double(height)
                var light = 0.0
                for point in points {
                    let dx = u - point.0
                    let dy = v - point.1
                    light += point.2 * exp(-(dx * dx + dy * dy) * 4_000)
                }
                let base = (y * width + x) * 4
                let value = UInt8(min(255, max(0, Int((0.03 + light) * 255))))
                pixels[base] = value
                pixels[base + 1] = value
                pixels[base + 2] = value
                pixels[base + 3] = 255
            }
        }
        pixels.withUnsafeBytes {
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: $0.baseAddress!,
                bytesPerRow: width * 4
            )
        }
    }

}

do {
    try BokehTransitionBench.run()
} catch {
    FileHandle.standardError.write(Data("BokehTransitionBench: \(error.localizedDescription)\n".utf8))
    exit(1)
}
