import AppKit
import MetalKit
import SwiftUI

@MainActor
private enum SkinSceneMetalContext {
    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()
}

/// Draws only when the scene timeline requests a frame. There is no second display loop.
struct SkinSceneShader: NSViewRepresentable {
    let path: String
    let function: String
    let data: SkinSceneData
    let snapshot: SkinSceneSnapshot
    let now: Double
    @Environment(\.skinPackageResources) private var root
    func makeNSView(context: Context) -> ShaderView { ShaderView() }
    func updateNSView(_ view: ShaderView, context: Context) {
        view.update(url: root.flatMap { try? SkinResourceResolver.resolve(path, root: $0) }, function: function, data: data, snapshot: snapshot, now: now)
    }
    static func dismantleNSView(_ view: ShaderView, coordinator: ()) { view.release() }

    final class ShaderView: NSView, MTKViewDelegate {
        private var metal: MTKView?
        private var pipeline: MTLRenderPipelineState?
        private var queue: MTLCommandQueue?
        private var texture: MTLTexture?
        private var key = ""
        private var artworkKey = ""
        private var uniforms = Uniforms()
        private let errorLabel = NSTextField(wrappingLabelWithString: "")
        private var failed = false

        struct Uniforms {
            var resolution = SIMD2<Float>(1, 1)
            var time: Float = 0
            var lyricsTime: Float = 0
            var progress: Float = 0
            var bass: Float = 0
            var mid: Float = 0
            var treble: Float = 0
            var accent = SIMD4<Float>(1, 1, 1, 1)
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            if let device = SkinSceneMetalContext.device {
                let view = MTKView(frame: bounds, device: device)
                view.colorPixelFormat = .bgra8Unorm; view.isPaused = true; view.enableSetNeedsDisplay = true
                view.framebufferOnly = true; view.delegate = self
                addSubview(view); metal = view; queue = SkinSceneMetalContext.queue
            }
            errorLabel.isHidden = true; errorLabel.textColor = .secondaryLabelColor
            addSubview(errorLabel)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() { super.layout(); metal?.frame = bounds; errorLabel.frame = bounds.insetBy(dx: 16, dy: 16) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(url: URL?, function: String, data: SkinSceneData, snapshot: SkinSceneSnapshot, now: Double) {
            let nextKey = "\(url?.path ?? "")#\(function)"
            if key != nextKey {
                key = nextKey; pipeline = nil; failed = false
                do {
                    guard let url, let device = metal?.device else { throw SkinPackageError.invalidManifest("着色器不可用") }
                    let source = try String(contentsOf: url, encoding: .utf8)
                    guard source.utf8.count <= 1024 * 1024 else { throw SkinPackageError.invalidManifest("着色器超过大小限制") }
                    let expectedKey = key
                    device.makeLibrary(source: Self.prelude + "\n" + source + "\n" + Self.fragment(function), options: nil) { [weak self] library, error in
                        Task { @MainActor [weak self] in
                            guard let self, self.key == expectedKey else { return }
                            do {
                                if let error { throw error }
                                guard let library else { throw SkinPackageError.invalidManifest("着色器编译失败") }
                                let descriptor = MTLRenderPipelineDescriptor()
                                descriptor.vertexFunction = library.makeFunction(name: "skinVertex")
                                descriptor.fragmentFunction = library.makeFunction(name: "skinMain")
                                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                                self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                                self.errorLabel.isHidden = true
                                self.metal?.needsDisplay = true
                            } catch { self.report(error.localizedDescription) }
                        }
                    }
                } catch { report(error.localizedDescription) }
            }
            guard !failed else { return }
            uniforms.time = Float(data.time(at: now)); uniforms.lyricsTime = Float(data.clock.lyricsTime(at: now))
            uniforms.progress = Float(data.clock.duration > 0 ? data.clock.position(at: now) / data.clock.duration : 0)
            uniforms.bass = Float(data.band(lowHz: 20, highHz: 150, now: now)); uniforms.mid = Float(data.band(lowHz: 400, highHz: 1200, now: now))
            uniforms.treble = Float(data.band(lowHz: 3500, highHz: 16000, now: now))
            let color = NSColor(snapshot.theme.accentColor).usingColorSpace(.sRGB) ?? .white
            uniforms.accent = SIMD4(Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent), Float(color.alphaComponent))
            let nextArtworkKey = "\(snapshot.track?.id.uuidString ?? "")#\(snapshot.track?.artworkChecksum ?? 0)"
            if artworkKey != nextArtworkKey || texture == nil {
                artworkKey = nextArtworkKey
                if let device = metal?.device {
                    let loader = MTKTextureLoader(device: device)
                    var rect = CGRect(origin: .zero, size: snapshot.track?.artworkImage?.size ?? CGSize(width: 1, height: 1))
                    if let image = snapshot.track?.artworkImage?.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                        texture = try? loader.newTexture(cgImage: image, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
                    } else {
                        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
                        texture = device.makeTexture(descriptor: descriptor)
                        var pixel: [UInt8] = [0, 0, 0, 255]
                        pixel.withUnsafeMutableBytes { bytes in
                            if let address = bytes.baseAddress { texture?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: address, bytesPerRow: 4) }
                        }
                    }
                }
            }
            metal?.needsDisplay = true
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { uniforms.resolution = SIMD2(Float(size.width), Float(size.height)) }
        func draw(in view: MTKView) {
            guard !failed, let pipeline, let texture, let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor, let command = queue?.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            uniforms.resolution = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
            command.present(drawable)
            command.addCompletedHandler { [weak self] buffer in
                if let error = buffer.error {
                    let message = error.localizedDescription
                    Task { @MainActor [weak self] in self?.report(message) }
                }
            }
            command.commit()
        }
        private func report(_ message: String) {
            failed = true; pipeline = nil
            errorLabel.stringValue = "着色器：\(message)"; errorLabel.isHidden = false
            Log.warning("Skin shader failed: \(message)", category: .ui)
        }
        func release() { key = ""; metal?.delegate = nil; metal?.isPaused = true; texture = nil; pipeline = nil; queue = nil }

        static let prelude = """
        #include <metal_stdlib>
        using namespace metal;
        struct SkinUniforms { float2 resolution; float time; float lyricsTime; float progress; float bass; float mid; float treble; float4 accent; };
        struct SkinVertex { float4 position [[position]]; float2 uv; };
        vertex SkinVertex skinVertex(uint id [[vertex_id]]) {
            float2 p = float2((id << 1) & 2, id & 2);
            return {float4(p * 2.0 - 1.0, 0, 1), float2(p.x, 1.0 - p.y)};
        }
        """
        static func fragment(_ function: String) -> String {
            """
            fragment float4 skinMain(SkinVertex in [[stage_in]], constant SkinUniforms& u [[buffer(0)]], texture2d<float> artwork [[texture(0)]]) {
                return \(function)(in.uv, u, artwork);
            }
            """
        }
    }
}
