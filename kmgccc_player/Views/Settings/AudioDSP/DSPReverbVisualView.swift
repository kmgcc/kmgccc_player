//
//  DSPReverbVisualView.swift
//  myPlayer2
//
//  Reverb picture: a rainbow light layer showing how much reverb each band
//  receives (decay time times wet level, computed from the parameters), and
//  particles that rise in loose columns, one per pair of bands, as many as
//  the band is loud, spreading wider the higher they climb.
//
//  Both layers draw into one CAMetalLayer. The light layer is two triangle
//  strips with a continuous hue; its fragment shader fades it smoothly from
//  the floor through a feathered band above the heights, so it has no edge.
//  The 48 heights follow parameter changes on the `layout` token and then
//  stop. Particles are drawn instanced in one call from a fixed ring; rise,
//  slowdown, spread and fade are computed on the GPU, so the CPU only spawns
//  new particles. Blending is ordinary alpha: no additive glow, blur,
//  stroke or shadow. Shaders compile at runtime from source, once per
//  process.
//

import AppKit
import Metal
import MotionKit
import QuartzCore
import SwiftUI

struct DSPReverbVisual: NSViewRepresentable {
    let parameters: DSPReverbParameters
    let isActive: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionPolicy) private var configuredMotionPolicy
    @Environment(\.motionTokens) private var motionTokens

    func makeNSView(context: Context) -> DSPReverbVisualView {
        DSPReverbVisualView()
    }

    func updateNSView(_ view: DSPReverbVisualView, context: Context) {
        view.motionPolicy = configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
        view.configure(
            amounts: Self.bandAmounts(for: parameters),
            layoutSpec: motionTokens[.layout],
            isDark: colorScheme == .dark,
            isActive: isActive
        )
    }

    static func dismantleNSView(_ view: DSPReverbVisualView, coordinator: ()) {
        view.stopListening()
    }

    /// Reverb received per band, 0…1: the band's decay time (relative to the
    /// longest the node can make) times the wet level, after the wet low cut
    /// and tone shelf. Compressed so short rooms remain visible.
    static func bandAmounts(for parameters: DSPReverbParameters) -> [Double] {
        let design = DSPReverbDesign(parameters: parameters)
        let wet = sin(min(max(parameters.mix, 0), 1) * Double.pi / 2)
        let toneGain = pow(10, design.toneDB / 20)
        return (0..<DSPCardSpectrumFeed.bandCount).map { band in
            let frequency = DSPCardSpectrumFeed.centerFrequency(ofBand: band)
            let decay = min(1, design.decaySeconds(at: frequency) / 4.5)
            let lowCut = 1 / (1 + pow(design.lowCutHz / frequency, 4)).squareRoot()
            let shelf = 1 / (1 + pow(3_000 / frequency, 2))
            let tone = 1 + (toneGain - 1) * shelf
            return min(1, pow(decay, 0.4) * pow(wet, 0.35) * lowCut * tone)
        }
    }
}

// MARK: - GPU resources

/// Device, queue and pipelines shared by every reverb card.
nonisolated final class DSPReverbGPU: @unchecked Sendable {
    static let shared = DSPReverbGPU()

    struct Pipelines {
        let mesh: MTLRenderPipelineState
        let particles: MTLRenderPipelineState
    }

    private enum State {
        case idle
        case compiling
        case ready(Pipelines)
        case failed
    }

    let device: MTLDevice?
    let queue: MTLCommandQueue?
    private let lock = NSLock()
    private var state = State.idle
    private var waiters: [@MainActor @Sendable () -> Void] = []

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
    }

    var pipelines: Pipelines? {
        lock.lock()
        defer { lock.unlock() }
        if case .ready(let pipelines) = state { return pipelines }
        return nil
    }

    /// Compiles the shaders once in the background; `onReady` runs on the
    /// main actor when they are available, or never if compilation failed.
    @MainActor
    func prepare(onReady: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        switch state {
        case .ready:
            lock.unlock()
            onReady()
            return
        case .failed:
            lock.unlock()
            return
        case .compiling:
            waiters.append(onReady)
            lock.unlock()
            return
        case .idle:
            waiters.append(onReady)
            state = .compiling
            lock.unlock()
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let built = build()
            lock.lock()
            state = built.map(State.ready) ?? .failed
            let due = waiters
            waiters.removeAll()
            lock.unlock()
            if built == nil { Log.error("DSP reverb visual shaders failed to compile", category: .ui) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { for waiter in due { waiter() } }
            }
        }
    }

    private func build() -> Pipelines? {
        guard let device,
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let meshVertex = library.makeFunction(name: "reverbMeshVertex"),
              let meshFragment = library.makeFunction(name: "reverbMeshFragment"),
              let particleVertex = library.makeFunction(name: "reverbParticleVertex"),
              let particleFragment = library.makeFunction(name: "reverbParticleFragment") else { return nil }

        func pipeline(_ vertex: MTLFunction, _ fragment: MTLFunction) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            // Premultiplied source-over: ordinary transparency.
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        guard let mesh = pipeline(meshVertex, meshFragment),
              let particles = pipeline(particleVertex, particleFragment) else { return nil }
        return Pipelines(mesh: mesh, particles: particles)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 viewport;
        float time;
        float life;
        float slowdown;
        float maxAlpha;
        float scale;
        float unused;
    };

    // Packed to match the 24-byte vertex written by the CPU.
    struct MeshVertex {
        packed_float2 position;
        packed_float4 color;
    };

    struct MeshOut {
        float4 position [[position]];
        float4 color;
    };

    vertex MeshOut reverbMeshVertex(uint vid [[vertex_id]],
                                    const device MeshVertex *vertices [[buffer(0)]]) {
        float2 position = float2(vertices[vid].position);
        MeshOut out;
        out.position = float4(position.x * 2.0 - 1.0, 1.0 - position.y * 2.0, 0.0, 1.0);
        out.color = float4(vertices[vid].color);
        return out;
    }

    struct MeshUniforms {
        float floorAlpha;
        float unused;
    };

    // The vertex alpha carries height in layer units: 0 at the floor, 1 at
    // the band height, 2 at the end of the feather above it. One smooth
    // curve over the whole span leaves no ridge where the two strips meet.
    fragment float4 reverbMeshFragment(MeshOut in [[stage_in]],
                                       constant MeshUniforms &u [[buffer(0)]]) {
        float fade = 1.0 - smoothstep(0.0, 2.0, clamp(in.color.a, 0.0, 2.0));
        float a = u.floorAlpha * pow(fade, 1.3);
        return float4(in.color.rgb * a, a);
    }

    struct Particle {
        float x;
        float birth;
        float speed;
        float size;
        float drift;
        float r;
        float g;
        float b;
    };

    struct ParticleOut {
        float4 position [[position]];
        float4 color;
        float2 uv;
        float radius;
    };

    vertex ParticleOut reverbParticleVertex(uint vid [[vertex_id]],
                                            uint iid [[instance_id]],
                                            const device Particle *particles [[buffer(0)]],
                                            constant Uniforms &u [[buffer(1)]]) {
        Particle p = particles[iid];
        float age = u.time - p.birth;
        float t = age / u.life;
        float2 corner = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
        ParticleOut out;
        out.uv = corner;
        if (p.size <= 0.0 || age < 0.0 || t >= 1.0) {
            out.position = float4(-2.0, -2.0, 0.0, 1.0);
            out.color = float4(0.0);
            out.radius = 1.0;
            return out;
        }
        // Launched upward, slowing exponentially toward its peak; the
        // sideways spread grows faster than the height, so a column leaves
        // its band narrow and loosens as it climbs.
        float rise = p.speed * (1.0 - exp(-u.slowdown * age)) / u.slowdown;
        float2 center = float2(p.x + p.drift * rise * (0.25 + 1.6 * rise), 1.0 - rise);
        float size = p.size * (1.0 - 0.35 * t);
        float2 position = center + corner * size / u.viewport;
        out.position = float4(position.x * 2.0 - 1.0, 1.0 - position.y * 2.0, 0.0, 1.0);
        float fade = pow(1.0 - t, 1.5) * smoothstep(0.0, 0.08, t);
        out.color = float4(p.r, p.g, p.b, fade * u.maxAlpha);
        out.radius = size * u.scale;
        return out;
    }

    fragment float4 reverbParticleFragment(ParticleOut in [[stage_in]]) {
        // A filled disc with a one-pixel antialiased edge.
        float edge = clamp((1.0 - length(in.uv)) * in.radius, 0.0, 1.0);
        float a = in.color.a * edge;
        return float4(in.color.rgb * a, a);
    }
    """
}

// MARK: - View

final class DSPReverbVisualView: DSPCardAnimatedView {
    private struct MeshVertex {
        var x: Float
        var y: Float
        var red: Float
        var green: Float
        var blue: Float
        var alpha: Float
    }

    private struct Particle {
        var x: Float = 0
        var birth: Float = 0
        var speed: Float = 0
        var size: Float = 0
        var drift: Float = 0
        var red: Float = 0
        var green: Float = 0
        var blue: Float = 0
    }

    private struct Uniforms {
        var viewport: SIMD2<Float>
        var time: Float
        var life: Float
        var slowdown: Float
        var maxAlpha: Float
        var scale: Float
        var unused: Float = 0
    }

    private struct MeshUniforms {
        var floorAlpha: Float
        var unused: Float = 0
    }

    private static let bandCount = DSPCardSpectrumFeed.bandCount
    /// Light-layer columns: the bands interpolated four times as finely.
    private static let columnCount = bandCount * 4
    /// Feather above the band heights, as a share of the view's height.
    private static let featherHeight = 0.24
    /// Particle columns: one per pair of bands, wide enough to read apart.
    private static let emitterCount = bandCount / 2
    private static let particleCapacity = 2_048
    private static let particleLife: Float = 1.4
    private static let slowdown: Float = 2.2
    /// Particles per second from one column at full level.
    private static let maximumRate = 32.0
    private static let framesInFlight = 3

    private let gpu = DSPReverbGPU.shared
    private var meshBuffers: [MTLBuffer] = []
    private var particleBuffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: DSPReverbVisualView.framesInFlight)

    private var heights: DSPFollowerBank
    private var emission: DSPFollowerBank
    private var layoutSpec = MotionTokens.standard[.layout]
    private var hasPlacedHeights = false
    private var isDark = false
    private var isActive = false
    private var emitterColors: [(red: Float, green: Float, blue: Float)] = []
    private var columnColors: [(red: Float, green: Float, blue: Float)] = []

    private var particles: [Particle]
    private var nextParticle = 0
    private var emissionCredit: [Double]
    private var inputBands = [Float](repeating: 0, count: DSPCardSpectrumFeed.bandCount)
    private var meshScratch: [MeshVertex]
    private var epoch: CFTimeInterval?
    private var lastFrameTime: CFTimeInterval?
    private var lastSpawnTime: CFTimeInterval = -.infinity
    private var random: UInt64 = 0x2545_F491_4F6C_DD1D
    private var holdsFeedLease = false

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override init(frame frameRect: NSRect) {
        heights = DSPFollowerBank(count: Self.bandCount, spec: MotionTokens.standard[.layout], policy: .full)
        emission = DSPFollowerBank(count: Self.emitterCount, spec: CapsuleSpectrumDynamics.standard.motionSpec,
                                   policy: .full)
        particles = Array(repeating: Particle(), count: Self.particleCapacity)
        emissionCredit = Array(repeating: 0, count: Self.emitterCount)
        meshScratch = Array(repeating: MeshVertex(x: 0, y: 0, red: 0, green: 0, blue: 0, alpha: 0),
                            count: Self.columnCount * 4)
        super.init(frame: frameRect)
        if let metalLayer {
            // The shaders already map y downward; the drawable is not flipped.
            metalLayer.isGeometryFlipped = false
            metalLayer.device = gpu.device
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = true
            metalLayer.isOpaque = false
            metalLayer.maximumDrawableCount = Self.framesInFlight
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        if let device = gpu.device {
            for _ in 0..<Self.framesInFlight {
                if let mesh = device.makeBuffer(length: MemoryLayout<MeshVertex>.stride * Self.columnCount * 4,
                                                options: .storageModeShared),
                   let particles = device.makeBuffer(length: MemoryLayout<Particle>.stride * Self.particleCapacity,
                                                     options: .storageModeShared) {
                    meshBuffers.append(mesh)
                    particleBuffers.append(particles)
                }
            }
        }
        gpu.prepare { [weak self] in
            self?.renderStill()
            self?.wake()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    func configure(amounts: [Double], layoutSpec: MotionSpec, isDark: Bool, isActive: Bool) {
        self.layoutSpec = layoutSpec
        heights.update(spec: layoutSpec, policy: motionPolicy)
        let time = CACurrentMediaTime()
        for (band, amount) in amounts.prefix(Self.bandCount).enumerated() {
            heights.setTarget(amount, at: band, time: time)
        }
        if !hasPlacedHeights {
            heights.snapAll()
            hasPlacedHeights = true
        }
        if isDark != self.isDark || columnColors.isEmpty {
            self.isDark = isDark
            let colors = DSPCardVisualColors(accent: .white, isDark: isDark)
            emitterColors = (0..<Self.emitterCount).map { emitter in
                colors.frequencyColor(position: (Double(emitter) + 0.5) / Double(Self.emitterCount))
            }
            // A continuous hue across the light layer, no steps between bands.
            columnColors = (0..<Self.columnCount).map { column in
                colors.frequencyColor(position: Double(column) / Double(Self.columnCount - 1))
            }
        }
        self.isActive = isActive
        wake()
    }

    func stopListening() {
        DSPCardSpectrumFeed.shared.cancelWake(owner: self)
        releaseFeed()
    }

    override func motionPolicyDidChange() {
        heights.update(spec: layoutSpec, policy: motionPolicy)
        emission.update(spec: CapsuleSpectrumDynamics.standard.motionSpec, policy: motionPolicy)
    }

    override func visibilityDidChange(_ isVisible: Bool) {
        if isVisible {
            acquireFeed()
        } else {
            DSPCardSpectrumFeed.shared.cancelWake(owner: self)
            releaseFeed()
        }
    }

    override func boundsDidChange() {
        guard let metalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        boundsDidChange()
        renderStill()
    }

    private func acquireFeed() {
        guard !holdsFeedLease else { return }
        holdsFeedLease = true
        DSPCardSpectrumFeed.shared.acquire()
    }

    private func releaseFeed() {
        guard holdsFeedLease else { return }
        holdsFeedLease = false
        DSPCardSpectrumFeed.shared.release()
    }

    // MARK: Frame

    override func renderFrame(at time: CFTimeInterval) -> Bool {
        let dt = lastFrameTime.map { min(0.1, max(0, time - $0)) } ?? 0
        lastFrameTime = time
        let sprays = motionPolicy == .full && isActive
        let level = DSPCardSpectrumFeed.shared.read(into: &inputBands)
        let hasSignal = sprays && level > 0

        // Each column follows its louder band, weighted a little by how much
        // reverb that band receives, and leans on the spectrum's shape: a
        // band well under the loudest one sprays visibly less.
        var loudest: Float = 0
        if hasSignal { loudest = inputBands.max() ?? 0 }
        for emitter in 0..<Self.emitterCount {
            var target = 0.0
            if hasSignal, loudest > 0 {
                let first = emitter * 2
                let band = Double(max(inputBands[first], inputBands[first + 1]))
                let reverb = max(heights.target(first), heights.target(first + 1))
                let shape = band / Double(loudest)
                target = band * (0.5 + 0.5 * shape) * (0.45 + 0.55 * reverb)
            }
            emission.setTarget(target, at: emitter, time: time, epsilon: 0.002)
        }
        let heightsMoving = heights.advance(to: time)
        let emissionMoving = emission.advance(to: time, epsilon: 0.002)
        if sprays, dt > 0 { spawnParticles(at: time, dt: dt) }

        let particlesAlive = time - lastSpawnTime < Double(Self.particleLife)
        if !particlesAlive { epoch = nil }
        draw(at: time)

        let keepRunning = heightsMoving || emissionMoving || particlesAlive || hasSignal
        if !keepRunning {
            lastFrameTime = nil
            if sprays, isVisibleOnScreen {
                DSPCardSpectrumFeed.shared.wakeOnNextUpdate(owner: self) { [weak self] in self?.wake() }
            }
        }
        return keepRunning
    }

    private func spawnParticles(at time: CFTimeInterval, dt: CFTimeInterval) {
        let start = epoch ?? time
        epoch = start
        let birth = Float(time - start)
        let columnWidth = 1 / Float(Self.emitterCount)
        for emitter in 0..<Self.emitterCount {
            let strength = min(1, max(0, emission.value(emitter)))
            guard strength > 0.03 else {
                emissionCredit[emitter] = 0
                continue
            }
            // Rate grows faster than level, so loud bands clearly outspray quiet ones.
            emissionCredit[emitter] += pow(strength, 1.6) * Self.maximumRate * dt
            while emissionCredit[emitter] >= 1 {
                emissionCredit[emitter] -= 1
                let color = emitterColors[emitter]
                let reach = Float(0.25 + 0.7 * strength) * (0.6 + 0.4 * nextRandom())
                // Born near the column's centre; the spread comes with height.
                let jitter = (nextRandom() - 0.5) * 0.3 * columnWidth
                particles[nextParticle] = Particle(
                    x: (Float(emitter) + 0.5) * columnWidth + jitter,
                    birth: birth - Float(dt) * nextRandom(),
                    speed: reach * Self.slowdown,
                    size: 1.4 + 2 * Float(strength) * nextRandom(),
                    drift: (nextRandom() - 0.5) * 1.3 * columnWidth,
                    red: color.red, green: color.green, blue: color.blue
                )
                nextParticle = (nextParticle + 1) % Self.particleCapacity
                lastSpawnTime = time
            }
        }
    }

    private func nextRandom() -> Float {
        random ^= random << 13
        random ^= random >> 7
        random ^= random << 17
        return Float(random >> 40) / Float(1 << 24)
    }

    private func draw(at time: CFTimeInterval) {
        guard let metalLayer, let pipelines = gpu.pipelines, let queue = gpu.queue,
              meshBuffers.count == Self.framesInFlight,
              bounds.width > 1, bounds.height > 1 else { return }
        // Never block the main thread: skip a frame if the GPU is behind.
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }

        let meshBuffer = meshBuffers[bufferIndex]
        let particleBuffer = particleBuffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % Self.framesInFlight
        fillMesh(into: meshBuffer)
        particles.withUnsafeBytes { source in
            particleBuffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }

        var uniforms = Uniforms(
            viewport: SIMD2(Float(bounds.width), Float(bounds.height)),
            time: Float(time - (epoch ?? time)),
            life: Self.particleLife,
            slowdown: Self.slowdown,
            maxAlpha: isDark ? 0.85 : 0.75,
            scale: Float(metalLayer.contentsScale)
        )

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return
        }
        var meshUniforms = MeshUniforms(floorAlpha: (isDark ? 0.34 : 0.3) * (isActive ? 1 : 0.5))
        encoder.setRenderPipelineState(pipelines.mesh)
        encoder.setVertexBuffer(meshBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&meshUniforms, length: MemoryLayout<MeshUniforms>.stride, index: 0)
        // Body strip, then the feather strip above it.
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: Self.columnCount * 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: Self.columnCount * 2,
                               vertexCount: Self.columnCount * 2)

        if epoch != nil {
            encoder.setRenderPipelineState(pipelines.particles)
            encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: Self.particleCapacity)
        }
        encoder.endEncoding()

        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Writes the light layer: a body strip from the floor to the band
    /// heights and a feather strip above it. The alpha slot carries the
    /// height in layer units (0, 1, 2); the fragment shader turns it into
    /// one smooth fade.
    private func fillMesh(into buffer: MTLBuffer) {
        let columns = Self.columnCount
        let feather = Float(Self.featherHeight)
        for column in 0..<columns {
            let x = Double(column) / Double(columns - 1)
            // Cosine interpolation between band centres keeps the edge smooth.
            let position = x * Double(Self.bandCount) - 0.5
            let lower = min(Self.bandCount - 1, max(0, Int(position.rounded(.down))))
            let upper = min(Self.bandCount - 1, lower + 1)
            let fraction = min(1, max(0, position - Double(lower)))
            let blend = (1 - cos(fraction * Double.pi)) / 2
            let amount = heights.value(lower) * (1 - blend) + heights.value(upper) * blend
            let top = Float(1 - (0.06 + 0.7 * min(1, max(0, amount))))
            let color = columnColors.isEmpty ? (red: Float(1), green: Float(1), blue: Float(1)) : columnColors[column]
            func vertex(_ y: Float, _ height: Float) -> MeshVertex {
                MeshVertex(x: Float(x), y: y, red: color.red, green: color.green, blue: color.blue, alpha: height)
            }
            meshScratch[column * 2] = vertex(top, 1)
            meshScratch[column * 2 + 1] = vertex(1, 0)
            meshScratch[(columns + column) * 2] = vertex(top - feather, 2)
            meshScratch[(columns + column) * 2 + 1] = vertex(top, 1)
        }
        meshScratch.withUnsafeBytes { source in
            buffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
    }
}
