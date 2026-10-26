//
//  CoverProgressiveBlurRenderer.swift
//  kmgccc_player
//
//  GPU progressive blur for the panorama cover background: the cover fills
//  the canvas height, its edge strip is stretched (or mirrored) across the
//  rest, and every column is blurred with its own Gaussian sigma.
//
//  The blur is separable. Sigma depends on x only, so the horizontal pass
//  runs first and the vertical pass then reads columns that all went through
//  the same horizontal kernel: each pixel gets exactly the 2D Gaussian of its
//  own sigma. The other order drags sharp rows of the stretched fill into the
//  blur as horizontal streaks.
//
//  Each pass reads a pyramid downsampled along its own axis only, picks the
//  level whose texel h = 2^k is at most sigma / density, and sums that level
//  with a Gaussian tapered by (1 - (d/R)^2)^2, R = 3s, in bilinear pairs:
//    - the taper reaches zero with zero slope, so texels entering the window
//      never step;
//    - the [1 3 3 1] downsamples contribute 0.25 (4^k - 1) px^2 of variance
//      and the kernel the rest, so the total is exactly sigma^2 at every
//      level and neighbouring radii never meet in a seam;
//    - levels k and k + 1 are mixed only in the last 30% of each octave,
//      where both already carry the target variance.
//  Cost per pass is about 3 * density + 1 fetches, independent of sigma.
//
//  Intermediates are 16-bit float; the output is 8-bit with a triangular
//  dither of one step, so slow gradients turn into fine grain, not bands.
//  The live path for the layout transition renders the same panorama every
//  frame into a 16-bit linear texture instead.
//

import CoreGraphics
import Foundation
import Metal

nonisolated enum CoverProgressiveBlurRenderer {
    nonisolated enum Placement: Sendable {
        case leading
        case centered
    }

    nonisolated enum EdgeFill: Sendable {
        case stretch
        case mirror
    }

    /// Dominant-colour tint over the fill, composited in linear light.
    nonisolated struct Overlay: Sendable {
        /// Linear-light Display P3 colour.
        var linearColor: SIMD3<Float>
        var maxAlpha: Float
        /// The tint starts this fraction of the cover width inside its edge
        /// and reaches `maxAlpha` at the canvas edge.
        var startRatioFromEdge: Double
    }

    nonisolated struct Request {
        var artwork: CGImage
        var pixelWidth: Int
        var pixelHeight: Int
        var pixelsPerPoint: Double
        var placement: Placement
        var edgeFill: EdgeFill
        var profile: CoverProgressiveBlurProfile
        var overlay: Overlay?
    }

    nonisolated struct Output {
        let image: CGImage
        let gpuMilliseconds: Double
    }

    /// The first access compiles the shaders (over a second when the system
    /// shader cache is cold), so launch touches it off the main thread.
    static var isAvailable: Bool { Engine.shared != nil }

    /// Blocks until the GPU finishes. Calls are serialised; each takes a few
    /// milliseconds at display resolution.
    static func render(_ request: Request) -> Output? {
        Engine.shared?.render(request)
    }

    /// One frame of a panorama whose cover moves, encoded by the caller.
    nonisolated struct LiveFrame {
        var pixelWidth: Int
        var pixelHeight: Int
        var pixelsPerPoint: Double
        /// Left edge and side of the square cover, in output pixels. The
        /// cover may extend past the canvas while a spring overshoots.
        var coverX0: Double
        var coverSide: Double
        var edgeFill: EdgeFill
        var profile: CoverProgressiveBlurProfile
        var lut: [Float]
        var overlay: Overlay?
        /// 0 tints only the right fill (leading), 1 both fills (centred).
        var overlayLeftWeight: Float
    }

    /// Per-surface state for rendering a panorama every display frame inside
    /// another command buffer. The output holds premultiplied linear light,
    /// so a following pass can work in light without decoding.
    nonisolated final class Live: @unchecked Sendable {
        private let kernels: Kernels
        private var work: WorkTextures?
        private var workWidth = 0
        private var workHeight = 0
        private var heap: MTLHeap?
        private var lutBuffers: [MTLBuffer] = []
        private var lutIndex = 0
        private var blendedCover: MTLTexture?

        init?(device: MTLDevice) {
            if let engine = Engine.shared, engine.kernels.device === device {
                kernels = engine.kernels
            } else if let kernels = Kernels(device: device) {
                self.kernels = kernels
            } else {
                return nil
            }
        }

        /// A square, center-cropped Display P3 cover of `side` pixels.
        func makeCoverTexture(_ artwork: CGImage, side: Int) -> MTLTexture? {
            kernels.makeCoverTexture(
                MotionArtworkFrameGeometry.centerSquareCrop(artwork),
                width: side,
                height: side
            )
        }

        /// `output` is an rgba16Float texture of the frame's size. Callers
        /// keep at most two frames in flight. A `previousCover` with a
        /// positive weight is dissolved into `cover` before the blur, so an
        /// artwork change stays one panorama.
        func encode(
            _ frame: LiveFrame,
            cover: MTLTexture,
            previousCover: MTLTexture? = nil,
            previousWeight: Float = 0,
            output: MTLTexture,
            into commandBuffer: MTLCommandBuffer
        ) -> Bool {
            let width = frame.pixelWidth
            let height = frame.pixelHeight
            guard width >= 8, height >= 8, frame.lut.count == width,
                  output.width == width, output.height == height else { return false }
            let xLevels = PyramidLevel.chain(for: width)
            let yLevels = PyramidLevel.chain(for: height)
            if workWidth != width || workHeight != height || work == nil {
                work = nil
                workWidth = width
                workHeight = height
                guard let made = kernels.makeWorkTextures(
                    width: width, height: height, xLevels: xLevels, yLevels: yLevels, heap: &heap
                ) else { return false }
                work = made
                lutBuffers = (0..<3).compactMap { _ in
                    kernels.device.makeBuffer(length: width * 4, options: .storageModeShared)
                }
            }
            guard let work, lutBuffers.count == 3 else { return false }
            let lutBuffer = lutBuffers[lutIndex]
            lutIndex = (lutIndex + 1) % lutBuffers.count
            frame.lut.withUnsafeBytes { bytes in
                lutBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }

            var uniforms = BlurUniforms.make(
                width: width,
                height: height,
                coverX0: frame.coverX0,
                coverWidth: frame.coverSide,
                pixelsPerPoint: frame.pixelsPerPoint,
                profile: frame.profile,
                edgeFill: frame.edgeFill,
                overlay: frame.overlay,
                overlayLeftWeight: frame.overlayLeftWeight
            )
            uniforms.linearOutput = 1
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
            encoder.label = "Live cover progressive blur"
            var source = cover
            if let previousCover, previousWeight > 0.001,
               let blended = blendTarget(width: cover.width, height: cover.height) {
                kernels.encodeMix(
                    encoder, from: cover, to: previousCover, weight: min(1, previousWeight), into: blended
                )
                source = blended
            }
            kernels.encode(
                encoder, uniforms: &uniforms, cover: source, work: work, output: output,
                lut: lutBuffer, xLevels: xLevels, yLevels: yLevels
            )
            encoder.endEncoding()
            return true
        }

        func releaseResources() {
            work = nil
            heap = nil
            lutBuffers = []
            blendedCover = nil
            workWidth = 0
            workHeight = 0
        }

        private func blendTarget(width: Int, height: Int) -> MTLTexture? {
            if let blendedCover, blendedCover.width == width, blendedCover.height == height {
                return blendedCover
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            blendedCover = kernels.device.makeTexture(descriptor: descriptor)
            return blendedCover
        }
    }
}

// MARK: - Engine

private nonisolated let maxLevels = 12

/// Matches `BlurUniforms` in the shader source.
private nonisolated struct BlurUniforms {
    var overlayColor = SIMD4<Float>(0, 0, 0, 0)
    var size = SIMD2<Float>(0, 0)
    var coverX0: Float = 0
    var coverX1: Float = 0
    var stripU: Float = 0
    var density: Float = 1.5
    var ditherStep: Float = 1.0 / 255.0
    var overlayRightStart: Float = 0
    var overlayRightEnd: Float = 1
    var overlayLeftStart: Float = 1
    var overlayLeftEnd: Float = 0
    var fillMode: Int32 = 0
    var levels: Int32 = 1
    var overlayMode: Int32 = 0
    var sourceLevel: Int32 = 0
    var overlayLeftWeight: Float = 1
    var linearOutput: Int32 = 0
    var padding0: Int32 = 0
    var padding1: Int32 = 0
    var padding2: Int32 = 0

    /// The canvas and tint geometry shared by settled and live renders.
    static func make(
        width: Int,
        height: Int,
        coverX0: Double,
        coverWidth: Double,
        pixelsPerPoint: Double,
        profile: CoverProgressiveBlurProfile,
        edgeFill: CoverProgressiveBlurRenderer.EdgeFill,
        overlay: CoverProgressiveBlurRenderer.Overlay?,
        overlayLeftWeight: Float
    ) -> BlurUniforms {
        let coverX1 = coverX0 + coverWidth
        var uniforms = BlurUniforms()
        uniforms.size = SIMD2(Float(width), Float(height))
        uniforms.coverX0 = Float(coverX0)
        uniforms.coverX1 = Float(coverX1)
        uniforms.stripU = Float(min(1, profile.strip * pixelsPerPoint / coverWidth))
        uniforms.density = Float(profile.density)
        uniforms.fillMode = edgeFill == .stretch ? 0 : 1
        if let overlay, overlay.maxAlpha > 0 {
            let inset = min(coverWidth, Double(width)) * overlay.startRatioFromEdge
            uniforms.overlayColor = SIMD4(overlay.linearColor, overlay.maxAlpha)
            uniforms.overlayRightStart = Float(coverX1 - inset)
            uniforms.overlayRightEnd = Float(max(Double(width), coverX1 - inset + 1))
            uniforms.overlayLeftStart = Float(coverX0 + inset)
            uniforms.overlayLeftEnd = Float(min(0, coverX0 + inset - 1))
            uniforms.overlayMode = overlayLeftWeight > 0 ? 2 : 1
            uniforms.overlayLeftWeight = overlayLeftWeight
        }
        return uniforms
    }
}

/// One pyramid level along a pass's axis. Levels above 0 store two extra
/// texels on each side, computed like the rest; the outer one covers only
/// repeated edge pixels, so clamping to it is exact at every level.
private nonisolated struct PyramidLevel {
    let length: Int
    let margin: Int

    var storedLength: Int { length + 2 * margin }
    /// margin, lowest and highest stored texel index, padding.
    var info: SIMD4<Float> {
        SIMD4(Float(margin), Float(-margin), Float(length - 1 + margin), 0)
    }

    /// Lengths round up: rounding down would drop the last row or column of
    /// an odd level, and coarser levels would no longer reach the edge.
    static func chain(for length: Int) -> [PyramidLevel] {
        var levels: [PyramidLevel] = []
        var n = length
        while levels.count < maxLevels, n >= 4 {
            levels.append(PyramidLevel(length: n, margin: levels.isEmpty ? 0 : 2))
            n = (n + 1) / 2
        }
        return levels
    }

    static func infoTable(_ levels: [PyramidLevel]) -> [SIMD4<Float>] {
        (0..<maxLevels).map { levels[min($0, levels.count - 1)].info }
    }
}

/// The compiled kernels and the resource helpers both render paths share.
private nonisolated final class Kernels: @unchecked Sendable {
    let device: MTLDevice
    private let downXFromCover: MTLComputePipelineState
    private let downX: MTLComputePipelineState
    private let downY: MTLComputePipelineState
    private let blurX: MTLComputePipelineState
    private let blurY: MTLComputePipelineState
    private let mixCovers: MTLComputePipelineState
    let displayP3: CGColorSpace

    init?(device: MTLDevice) {
        guard MemoryLayout<BlurUniforms>.stride == 96,
              let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        do {
            let library = try device.makeLibrary(source: shaderSource, options: MTLCompileOptions())
            func pipeline(_ name: String) throws -> MTLComputePipelineState {
                guard let function = library.makeFunction(name: name) else {
                    throw CocoaError(.featureUnsupported)
                }
                return try device.makeComputePipelineState(function: function)
            }
            downXFromCover = try pipeline("downXFromCover")
            downX = try pipeline("downX")
            downY = try pipeline("downY")
            blurX = try pipeline("blurX")
            blurY = try pipeline("blurY")
            mixCovers = try pipeline("mixCovers")
        } catch {
            return nil
        }
        self.device = device
        self.displayP3 = displayP3
    }

    /// The cover in Display P3 at the given size, drawn with high-quality
    /// resampling so the bilinear reads of the blur never skip source pixels.
    func makeCoverTexture(_ artwork: CGImage, width coverWidth: Int, height coverHeight: Int) -> MTLTexture? {
        guard coverWidth > 0, coverHeight > 0 else { return nil }
        let alignment = device.minimumLinearTextureAlignment(for: .rgba8Unorm)
        let bytesPerRow = (coverWidth * 4 + alignment - 1) / alignment * alignment
        guard let buffer = device.makeBuffer(length: bytesPerRow * coverHeight, options: .storageModeShared),
              let context = CGContext(
                  data: buffer.contents(),
                  width: coverWidth,
                  height: coverHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: displayP3,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        context.draw(artwork, in: CGRect(x: 0, y: 0, width: coverWidth, height: coverHeight))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: coverWidth, height: coverHeight, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        return buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: bytesPerRow)
    }

    /// Both passes into `output`: horizontal pyramid and blur, then the
    /// vertical ones, then tint and either dithered 8-bit or linear output.
    func encode(
        _ encoder: MTLComputeCommandEncoder,
        uniforms: inout BlurUniforms,
        cover: MTLTexture,
        work: WorkTextures,
        output: MTLTexture,
        lut: MTLBuffer,
        xLevels: [PyramidLevel],
        yLevels: [PyramidLevel]
    ) {
        let width = output.width
        let height = output.height
        let xInfo = PyramidLevel.infoTable(xLevels)
        let yInfo = PyramidLevel.infoTable(yLevels)

        // Horizontal levels. Level 0 is never stored: the kernels sample the
        // cover through the edge fill wherever they need it.
        if xLevels.count > 1 {
            uniforms.sourceLevel = 0
            encoder.setComputePipelineState(downXFromCover)
            encoder.setTexture(cover, index: 0)
            encoder.setTexture(work.x[1], index: 1)
            setConstants(encoder, &uniforms, xInfo)
            dispatch(encoder, downXFromCover, width: work.x[1]!.width, height: height)
            for k in 2..<xLevels.count {
                uniforms.sourceLevel = Int32(k - 1)
                encoder.setComputePipelineState(downX)
                encoder.setTexture(work.x[k - 1], index: 0)
                encoder.setTexture(work.x[k], index: 1)
                setConstants(encoder, &uniforms, xInfo)
                dispatch(encoder, downX, width: work.x[k]!.width, height: height)
            }
        }

        // Horizontal blur into level 0 of the vertical pyramid.
        uniforms.levels = Int32(xLevels.count)
        encoder.setComputePipelineState(blurX)
        encoder.setTexture(cover, index: 0)
        encoder.setTextures(
            paddedLevels(work.x, fallback: work.x.compactMap { $0 }.last ?? work.y0),
            range: 1..<(1 + maxLevels)
        )
        encoder.setTexture(work.y0, index: 1 + maxLevels)
        setConstants(encoder, &uniforms, xInfo)
        encoder.setBuffer(lut, offset: 0, index: 2)
        dispatch(encoder, blurX, width: width, height: height)

        // Vertical levels. They reuse the memory of the horizontal ones.
        for k in 1..<yLevels.count {
            uniforms.sourceLevel = Int32(k - 1)
            encoder.setComputePipelineState(downY)
            encoder.setTexture(k == 1 ? work.y0 : work.y[k - 1], index: 0)
            encoder.setTexture(work.y[k], index: 1)
            setConstants(encoder, &uniforms, yInfo)
            dispatch(encoder, downY, width: width, height: work.y[k]!.height)
        }

        // Vertical blur, tint and dither into the output.
        var yTextures = work.y
        yTextures[0] = work.y0
        uniforms.levels = Int32(yLevels.count)
        encoder.setComputePipelineState(blurY)
        encoder.setTextures(paddedLevels(yTextures, fallback: work.y0), range: 0..<maxLevels)
        encoder.setTexture(output, index: maxLevels)
        setConstants(encoder, &uniforms, yInfo)
        encoder.setBuffer(lut, offset: 0, index: 2)
        dispatch(encoder, blurY, width: width, height: height)
    }

    /// `weight` of `to` over `from`, resampled to `dst`'s size.
    func encodeMix(
        _ encoder: MTLComputeCommandEncoder,
        from: MTLTexture,
        to: MTLTexture,
        weight: Float,
        into dst: MTLTexture
    ) {
        var weight = weight
        encoder.setComputePipelineState(mixCovers)
        encoder.setTexture(from, index: 0)
        encoder.setTexture(to, index: 1)
        encoder.setTexture(dst, index: 2)
        encoder.setBytes(&weight, length: MemoryLayout<Float>.stride, index: 0)
        dispatch(encoder, mixCovers, width: dst.width, height: dst.height)
    }

    /// Intermediates sit in one placement heap. The horizontal and vertical
    /// levels never live at the same time, so they share memory; only the
    /// horizontal blur's output spans both phases. The heap is kept for the
    /// next render (video frames, transitions) and freed when renders stop.
    func makeWorkTextures(
        width: Int,
        height: Int,
        xLevels: [PyramidLevel],
        yLevels: [PyramidLevel],
        heap: inout MTLHeap?
    ) -> WorkTextures? {
        func descriptor(_ w: Int, _ h: Int) -> MTLTextureDescriptor {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
            )
            d.storageMode = .private
            d.usage = [.shaderRead, .shaderWrite]
            return d
        }
        var cursor = 0
        func place(_ d: MTLTextureDescriptor) -> Int {
            let sizeAndAlign = device.heapTextureSizeAndAlign(descriptor: d)
            let align = max(1, sizeAndAlign.align)
            let offset = (cursor + align - 1) / align * align
            cursor = offset + sizeAndAlign.size
            return offset
        }

        let y0Descriptor = descriptor(width, height)
        let y0Offset = place(y0Descriptor)
        let shared = cursor
        let xPlacements = xLevels.indices.dropFirst().map { k -> (MTLTextureDescriptor, Int) in
            let d = descriptor(xLevels[k].storedLength, height)
            return (d, place(d))
        }
        let xEnd = cursor
        cursor = shared
        let yPlacements = yLevels.indices.dropFirst().map { k -> (MTLTextureDescriptor, Int) in
            let d = descriptor(width, yLevels[k].storedLength)
            return (d, place(d))
        }
        let required = max(xEnd, cursor)

        if heap == nil || heap!.size < required {
            heap = nil
            let heapDescriptor = MTLHeapDescriptor()
            heapDescriptor.type = .placement
            heapDescriptor.storageMode = .private
            heapDescriptor.hazardTrackingMode = .tracked
            heapDescriptor.size = required
            heap = device.makeHeap(descriptor: heapDescriptor)
            heap?.label = "Cover progressive blur"
        }
        guard let heap, let y0 = heap.makeTexture(descriptor: y0Descriptor, offset: y0Offset) else {
            return nil
        }
        var x: [MTLTexture?] = [nil]
        for (d, offset) in xPlacements {
            guard let texture = heap.makeTexture(descriptor: d, offset: offset) else { return nil }
            x.append(texture)
        }
        var y: [MTLTexture?] = [nil]
        for (d, offset) in yPlacements {
            guard let texture = heap.makeTexture(descriptor: d, offset: offset) else { return nil }
            y.append(texture)
        }
        return WorkTextures(x: x, y0: y0, y: y)
    }

    /// Fills every slot of the shader's level array; unused slots repeat a
    /// valid texture and are never read.
    private func paddedLevels(_ levels: [MTLTexture?], fallback: MTLTexture) -> [MTLTexture?] {
        (0..<maxLevels).map { k in k < levels.count ? (levels[k] ?? fallback) : fallback }
    }

    private func setConstants(
        _ encoder: MTLComputeCommandEncoder,
        _ uniforms: inout BlurUniforms,
        _ info: [SIMD4<Float>]
    ) {
        encoder.setBytes(&uniforms, length: MemoryLayout<BlurUniforms>.stride, index: 0)
        info.withUnsafeBytes { bytes in
            encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        _ pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, min(pipeline.maxTotalThreadsPerThreadgroup, 256) / threadWidth)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        // Horizontal and vertical levels alias the same heap memory.
        encoder.memoryBarrier(scope: .textures)
    }
}

private nonisolated struct WorkTextures {
    /// Index 0 is empty: horizontal level 0 is the cover itself.
    var x: [MTLTexture?]
    var y0: MTLTexture
    /// Index 0 is empty: vertical level 0 is `y0`.
    var y: [MTLTexture?]
}

/// Settled renders: one blocking render at a time into a CGImage.
private nonisolated final class Engine: @unchecked Sendable {
    static let shared: Engine? = Engine()

    let kernels: Kernels
    private let queue: MTLCommandQueue

    /// Serialises renders; the cached heap is reused by the next one.
    private let lock = NSLock()
    private var heap: MTLHeap?
    private var heapGeneration = 0

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let kernels = Kernels(device: device) else { return nil }
        queue.label = "kmgccc.progressiveBlur"
        self.kernels = kernels
        self.queue = queue
    }

    func render(_ request: CoverProgressiveBlurRenderer.Request) -> CoverProgressiveBlurRenderer.Output? {
        let width = request.pixelWidth
        let height = request.pixelHeight
        // Every cover is shown square: off-square artwork is center-cropped.
        let artwork = MotionArtworkFrameGeometry.centerSquareCrop(request.artwork)
        guard width >= 8, height >= 8, width <= 16_000, height <= 16_000,
              artwork.width > 0, artwork.height > 0 else { return nil }

        // The square cover fills the canvas height.
        let coverWidth = Double(height)
        let coverX0 = request.placement == .centered ? (Double(width) - coverWidth) / 2 : 0
        let lut = request.profile.sigmaLUT(
            width: width,
            coverX0: coverX0,
            coverX1: coverX0 + coverWidth,
            sides: request.placement == .centered ? .both : .right,
            pixelsPerPoint: request.pixelsPerPoint
        )
        let xLevels = PyramidLevel.chain(for: width)
        let yLevels = PyramidLevel.chain(for: height)
        var uniforms = BlurUniforms.make(
            width: width,
            height: height,
            coverX0: coverX0,
            coverWidth: coverWidth,
            pixelsPerPoint: request.pixelsPerPoint,
            profile: request.profile,
            edgeFill: request.edgeFill,
            overlay: request.overlay,
            overlayLeftWeight: request.placement == .centered ? 1 : 0
        )

        // At most slightly larger than drawn, so bilinear reads skip nothing.
        let coverSide = Double(artwork.height) > Double(height) * 1.25 ? height : artwork.height

        lock.lock()
        defer { lock.unlock() }

        guard let cover = kernels.makeCoverTexture(artwork, width: coverSide, height: coverSide),
              let output = makeOutputTarget(width: width, height: height),
              let lutBuffer = lut.withUnsafeBytes({ bytes in
                  kernels.device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
              }),
              let work = kernels.makeWorkTextures(
                  width: width, height: height, xLevels: xLevels, yLevels: yLevels, heap: &heap
              ),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        commandBuffer.label = "Cover progressive blur"
        kernels.encode(
            encoder, uniforms: &uniforms, cover: cover, work: work, output: output.texture,
            lut: lutBuffer, xLevels: xLevels, yLevels: yLevels
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        scheduleHeapRelease()
        guard commandBuffer.status == .completed,
              let image = makeImage(output, width: width, height: height) else { return nil }
        let gpuSeconds = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        return CoverProgressiveBlurRenderer.Output(image: image, gpuMilliseconds: gpuSeconds * 1000)
    }

    // MARK: Resources

    private nonisolated struct OutputTarget {
        let buffer: MTLBuffer
        let texture: MTLTexture
        let bytesPerRow: Int
    }

    /// The output texture lives in a shared buffer that the CGImage then
    /// wraps without a copy.
    private func makeOutputTarget(width: Int, height: Int) -> OutputTarget? {
        let device = kernels.device
        let alignment = device.minimumLinearTextureAlignment(for: .rgba8Unorm)
        let bytesPerRow = (width * 4 + alignment - 1) / alignment * alignment
        guard let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else {
            return nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderWrite
        guard let texture = buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: bytesPerRow) else {
            return nil
        }
        return OutputTarget(buffer: buffer, texture: texture, bytesPerRow: bytesPerRow)
    }

    private func makeImage(_ output: OutputTarget, width: Int, height: Int) -> CGImage? {
        let retained = Unmanaged.passRetained(output.buffer as AnyObject)
        guard let provider = CGDataProvider(
            dataInfo: retained.toOpaque(),
            data: output.buffer.contents(),
            size: output.bytesPerRow * height,
            releaseData: { info, _, _ in
                guard let info else { return }
                Unmanaged<AnyObject>.fromOpaque(info).release()
            }
        ) else {
            retained.release()
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: output.bytesPerRow,
            space: kernels.displayP3,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private func scheduleHeapRelease() {
        heapGeneration &+= 1
        let generation = heapGeneration
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.heapGeneration == generation { self.heap = nil }
            self.lock.unlock()
        }
    }
}

// MARK: - Shaders

private nonisolated let shaderSource = """
#include <metal_stdlib>
using namespace metal;

#define MAX_LEVELS 12
constant float KERNEL_VAR = 0.6324;   // variance of the tapered kernel, in s^2

struct BlurUniforms {
    float4 overlayColor;
    float2 size;
    float coverX0;
    float coverX1;
    float stripU;
    float density;
    float ditherStep;
    float overlayRightStart;
    float overlayRightEnd;
    float overlayLeftStart;
    float overlayLeftEnd;
    int fillMode;
    int levels;
    int overlayMode;
    int sourceLevel;
    float overlayLeftWeight;
    int linearOutput;
    int padding0;
    int padding1;
    int padding2;
};

constexpr sampler pixelSampler(coord::pixel, address::clamp_to_edge, filter::linear);
constexpr sampler coverSampler(coord::normalized, address::clamp_to_edge, filter::linear);

// A dissolve between two covers, for an artwork change mid-transition.
kernel void mixCovers(texture2d<float> from [[texture(0)]],
                      texture2d<float> to [[texture(1)]],
                      texture2d<float, access::write> dst [[texture(2)]],
                      constant float& weight [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    dst.write(mix(from.sample(coverSampler, uv), to.sample(coverSampler, uv), weight), gid);
}

// Canvas pixel at (x, y), pixel-centre coordinates: the cover, or the edge
// fill beside it.
static float4 baseAt(texture2d<float> cover, float x, float y, constant BlurUniforms& u) {
    float width = u.size.x;
    float s = (x - u.coverX0) / (u.coverX1 - u.coverX0);
    if (u.fillMode == 0) {
        if (s > 1.0) s = 1.0 - u.stripU * clamp((x - u.coverX1) / max(width - u.coverX1, 1.0), 0.0, 1.0);
        else if (s < 0.0) s = u.stripU * clamp((u.coverX0 - x) / max(u.coverX0, 1.0), 0.0, 1.0);
    } else {
        s = 1.0 - abs(s - 2.0 * floor(s * 0.5) - 1.0);
    }
    return cover.sample(coverSampler, float2(s, y / u.size.y));
}

// Horizontal level 0 at texel position p (texel j at j), linearly
// interpolated like a bilinear fetch.
static float4 level0X(texture2d<float> cover, float p, float y, constant BlurUniforms& u) {
    float last = u.size.x - 1.0;
    p = clamp(p, 0.0, last);
    float j = floor(p), f = p - j;
    float4 a = baseAt(cover, j + 0.5, y, u);
    if (f <= 0.0) return a;
    return mix(a, baseAt(cover, min(j + 1.0, last) + 0.5, y, u), f);
}

// One level down along one axis: [1 3 3 1]/8 as two bilinear fetches.
kernel void downXFromCover(texture2d<float> cover [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant BlurUniforms& u [[buffer(0)]],
                           constant float4* info [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float i = float(gid.x) - info[1].x;
    float lo = info[0].y, hi = info[0].z, y = float(gid.y) + 0.5;
    float a = clamp(2.0 * i - 0.25, lo, hi), b = clamp(2.0 * i + 1.25, lo, hi);
    dst.write(0.5 * (level0X(cover, a, y, u) + level0X(cover, b, y, u)), gid);
}

kernel void downX(texture2d<float> src [[texture(0)]],
                  texture2d<float, access::write> dst [[texture(1)]],
                  constant BlurUniforms& u [[buffer(0)]],
                  constant float4* info [[buffer(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    int k = u.sourceLevel;
    float i = float(gid.x) - info[k + 1].x;
    float lo = info[k].y, hi = info[k].z, off = info[k].x + 0.5, y = float(gid.y) + 0.5;
    float a = clamp(2.0 * i - 0.25, lo, hi), b = clamp(2.0 * i + 1.25, lo, hi);
    dst.write(0.5 * (src.sample(pixelSampler, float2(off + a, y)) + src.sample(pixelSampler, float2(off + b, y))), gid);
}

kernel void downY(texture2d<float> src [[texture(0)]],
                  texture2d<float, access::write> dst [[texture(1)]],
                  constant BlurUniforms& u [[buffer(0)]],
                  constant float4* info [[buffer(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    int k = u.sourceLevel;
    float i = float(gid.y) - info[k + 1].x;
    float lo = info[k].y, hi = info[k].z, off = info[k].x + 0.5, x = float(gid.x) + 0.5;
    float a = clamp(2.0 * i - 0.25, lo, hi), b = clamp(2.0 * i + 1.25, lo, hi);
    dst.write(0.5 * (src.sample(pixelSampler, float2(x, off + a)) + src.sample(pixelSampler, float2(x, off + b))), gid);
}

// Kernel scale s (level texels) for sigma at level k, after the variance the
// downsamples already contributed.
static float levelScale(int k, float sg) {
    float h = exp2(float(k));
    return sqrt(max(sg * sg - 0.25 * (h * h - 1.0), 1e-4) / KERNEL_VAR) / h;
}

// Tapered Gaussian over level k around pixel-centre position pos, summed in
// bilinear pairs (one fetch per two texels). FETCH reads position p of level
// k along the pass's axis; `other` is the pixel-centre coordinate across it.
#define BLUR_LEVEL(NAME, FETCH, ...)                                          \\
static float4 NAME(__VA_ARGS__, int k, float sg, float pos,                  \\
                   constant BlurUniforms& u, constant float4* info) {        \\
    float h = exp2(float(k));                                                \\
    float s = levelScale(k, sg);                                             \\
    float R = 3.0 * s, inv = -0.5 / (s * s), invR = 1.0 / (R * R);          \\
    float c = pos / h - 0.5, lo = info[k].y, hi = info[k].z;                 \\
    float off = info[k].x + 0.5;                                             \\
    int j0 = int(ceil(c - R)), j1 = int(floor(c + R));                       \\
    float4 sum = float4(0.0);                                                \\
    float wsum = 0.0;                                                        \\
    for (int j = j0; j <= j1; j += 2) {                                      \\
        float da = float(j) - c, db = da + 1.0;                              \\
        float ua = max(1.0 - da * da * invR, 0.0);                           \\
        float ub = max(1.0 - db * db * invR, 0.0);                           \\
        float wa = exp(da * da * inv) * ua * ua;                             \\
        float wb = exp(db * db * inv) * ub * ub;                             \\
        float w = wa + wb;                                                   \\
        if (w <= 0.0) continue;                                              \\
        float p = clamp(float(j) + wb / w, lo, hi);                          \\
        sum += w * (FETCH);                                                  \\
        wsum += w;                                                           \\
    }                                                                        \\
    return sum / wsum;                                                       \\
}

// Level 0 has its own function: folded into one fetch expression, the compiler
// may evaluate both sides for every tap.
BLUR_LEVEL(blurLevelX0,
           level0X(cover, p, other, u),
           texture2d<float> cover, float other)

BLUR_LEVEL(blurLevelXk,
           tex.sample(pixelSampler, float2(off + p, other)),
           texture2d<float> tex, float other)

static float4 blurLevelX(texture2d<float> cover, texture2d<float> tex, float other, int k, float sg, float pos,
                         constant BlurUniforms& u, constant float4* info) {
    if (k == 0) return blurLevelX0(cover, other, k, sg, pos, u, info);
    return blurLevelXk(tex, other, k, sg, pos, u, info);
}

BLUR_LEVEL(blurLevelY,
           tex.sample(pixelSampler, float2(other, off + p)),
           texture2d<float> tex, float other)

// Level k below sigma / density, blended toward k + 1 late in each octave.
static int pickLevel(float sg, constant BlurUniforms& u, thread float& t) {
    float lam = log2(sg / u.density);
    int k = clamp(int(floor(lam)), 0, u.levels - 1);
    t = (lam >= 0.0 && k < u.levels - 1) ? smoothstep(0.7, 1.0, lam - float(k)) : 0.0;
    return k;
}

static float sigmaAt(device const float* lut, uint x) {
    float s = lut[x];
    return s < 0.05 ? 0.0 : s;
}

kernel void blurX(texture2d<float> cover [[texture(0)]],
                  array<texture2d<float>, MAX_LEVELS> levels [[texture(1)]],
                  texture2d<float, access::write> dst [[texture(13)]],
                  constant BlurUniforms& u [[buffer(0)]],
                  constant float4* info [[buffer(1)]],
                  device const float* lut [[buffer(2)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float x = float(gid.x) + 0.5, y = float(gid.y) + 0.5;
    float sg = sigmaAt(lut, gid.x);
    float4 c;
    if (sg < 0.3) {
        c = baseAt(cover, x, y, u);
    } else {
        float t;
        int k = pickLevel(sg, u, t);
        c = t < 1.0 ? blurLevelX(cover, levels[k], y, k, sg, x, u, info) : float4(0.0);
        if (t > 0.0) c = mix(c, blurLevelX(cover, levels[k + 1], y, k + 1, sg, x, u, info), t);
    }
    dst.write(c, gid);
}

static float3 toLinear(float3 c) {
    c = max(c, 0.0);
    return select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= 0.04045);
}

static float3 toEncoded(float3 c) {
    c = max(c, 0.0);
    return select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c * 12.92, c <= 0.0031308);
}

static uint hashU(uint x) {
    x ^= x >> 16; x *= 0x7feb352dU;
    x ^= x >> 15; x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

static float rand01(uint2 p, uint salt) {
    return float(hashU(p.x + hashU(p.y * 0x9e3779b9U + salt))) * (1.0 / 4294967296.0);
}

kernel void blurY(array<texture2d<float>, MAX_LEVELS> levels [[texture(0)]],
                  texture2d<float, access::write> dst [[texture(12)]],
                  constant BlurUniforms& u [[buffer(0)]],
                  constant float4* info [[buffer(1)]],
                  device const float* lut [[buffer(2)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float x = float(gid.x) + 0.5, y = float(gid.y) + 0.5;
    float sg = sigmaAt(lut, gid.x);
    float4 c;
    if (sg < 0.3) {
        c = levels[0].read(gid);
    } else {
        float t;
        int k = pickLevel(sg, u, t);
        c = t < 1.0 ? blurLevelY(levels[k], x, k, sg, y, u, info) : float4(0.0);
        if (t > 0.0) c = mix(c, blurLevelY(levels[k + 1], x, k + 1, sg, y, u, info), t);
    }

    float3 rgb = c.rgb;
    float a = c.a;
    if (u.overlayMode != 0 || u.linearOutput != 0) {
        float3 straight = a > 0.0 ? rgb / a : float3(0.0);
        float3 lin = toLinear(straight) * a;
        if (u.overlayMode != 0) {
            float t = clamp((x - u.overlayRightStart) / (u.overlayRightEnd - u.overlayRightStart), 0.0, 1.0);
            if (u.overlayMode == 2) {
                float left = clamp((x - u.overlayLeftStart) / (u.overlayLeftEnd - u.overlayLeftStart), 0.0, 1.0);
                t = max(t, left * u.overlayLeftWeight);
            }
            float oa = t * u.overlayColor.a;
            lin = lin * (1.0 - oa) + u.overlayColor.rgb * oa;
            a = a * (1.0 - oa) + oa;
        }
        // Premultiplied linear light for a following pass; no dither needed.
        if (u.linearOutput != 0) {
            dst.write(float4(lin, saturate(a)), gid);
            return;
        }
        rgb = a > 0.0 ? toEncoded(lin / a) * a : float3(0.0);
    }
    // Triangular dither of one output step.
    rgb += (rand01(gid, 1u) + rand01(gid, 2u) - 1.0) * u.ditherStep;
    dst.write(float4(saturate(rgb), saturate(a)), gid);
}
"""
