//
//  DSPReverbVisualView.swift
//  myPlayer2
//
//  Reverb picture: a light layer showing how much reverb each band receives
//  (decay time times wet level, computed from the parameters), and particles
//  that rise in loose columns, one per pair of bands, as many as the band is
//  loud. The colours are the artwork's swatches from ThemeStore, spread from
//  low to high frequency, and glide to the next song's set. Night uses bright
//  tones and day dark ones, whatever the artwork's own lightness. Particles
//  read their column's colour every frame, so a change of palette or
//  appearance recolours the ones already in the air.
//
//  The parameters shape the motion as well as the heights: decay sets how
//  long particles live and how high they climb, room size their size, sway
//  and the softness of the light's edge, mix their density and the light's
//  strength, width how far the columns fan out, and pre-delay how late a
//  particle appears. While music plays, the light swells a little with the
//  live spectrum.
//
//  Both layers draw into one CAMetalLayer. The light layer is two triangle
//  strips; its fragment shader fades it smoothly from the floor through a
//  feathered band above the heights, so it has no edge. Particles are drawn
//  instanced in one call from a fixed ring; rise, slowdown, spread, sway and
//  fade are computed on the GPU, so the CPU only spawns new particles.
//  Blending is ordinary alpha: no additive glow, blur, stroke or shadow.
//  Shaders compile at runtime from source, once per process.
//

import AppKit
import Metal
import MotionKit
import QuartzCore
import SwiftUI

struct DSPReverbVisual: NSViewRepresentable {
    let parameters: DSPReverbParameters
    let isActive: Bool
    /// Colours from low to high frequency; empty falls back to a hue sweep.
    let palette: [Color]

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
            look: Look(parameters: parameters),
            palette: palette.map { NSColor($0) },
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

    /// The parameters that shape the motion, each 0…1.
    struct Look: Equatable {
        /// Mid-band decay on a log scale from 0.15 s to 4.5 s.
        var decay: Double
        var size: Double
        var mix: Double
        var width: Double
        /// Pre-delay over 0…200 ms.
        var preDelay: Double

        init(parameters: DSPReverbParameters) {
            func unit(_ value: Double) -> Double { min(1, max(0, value)) }
            decay = unit(log(parameters.midDecaySeconds / 0.15) / log(4.5 / 0.15))
            size = unit(parameters.size)
            mix = unit(parameters.mix)
            width = unit(parameters.width)
            preDelay = unit(parameters.preDelayMs / 200)
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
        float fadeIn;
        float slowdown;
        float maxAlpha;
        float scale;
        float swayRate;
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
        float life;
        float sway;
        float phase;
        float lane;
        float pad0;
        float pad1;
        float pad2;
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
                                            constant Uniforms &u [[buffer(1)]],
                                            constant float4 *emitterColors [[buffer(2)]]) {
        Particle p = particles[iid];
        float age = u.time - p.birth;
        float t = age / max(p.life, 0.01);
        float2 corner = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
        ParticleOut out;
        out.uv = corner;
        if (p.size <= 0.0 || age < 0.0 || t >= 1.0) {
            out.position = float4(-2.0, -2.0, 0.0, 1.0);
            out.color = float4(0.0);
            out.radius = 1.0;
            return out;
        }
        // Launched upward, slowing exponentially; the strongest are still
        // moving when they leave through the top. The sideways drift and a
        // slow sway grow with the height, held in check above the top so a
        // column loosens without dissolving.
        float rise = p.speed * (1.0 - exp(-u.slowdown * age)) / u.slowdown;
        float spread = rise * (0.4 + 0.8 * min(rise, 1.2));
        float sway = p.sway * sin(p.phase + age * u.swayRate) * min(rise, 1.2);
        float2 center = float2(p.x + p.drift * spread + sway, 1.0 - rise);
        float size = p.size * (1.0 - 0.3 * t);
        float2 position = center + corner * size / u.viewport;
        out.position = float4(position.x * 2.0 - 1.0, 1.0 - position.y * 2.0, 0.0, 1.0);
        // Full strength for most of the life, then a quick, smooth fade.
        float fade = (1.0 - smoothstep(0.5, 1.0, t)) * smoothstep(0.0, u.fadeIn, t);
        out.color = float4(emitterColors[uint(p.lane)].rgb, fade * u.maxAlpha);
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
    private typealias RGB = (red: Float, green: Float, blue: Float)

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
        var life: Float = 1
        var sway: Float = 0
        var phase: Float = 0
        /// Emitter index into the colour table, read on the GPU each frame.
        var lane: Float = 0
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    private struct Uniforms {
        var viewport: SIMD2<Float>
        var time: Float
        var fadeIn: Float
        var slowdown: Float
        var maxAlpha: Float
        var scale: Float
        var swayRate: Float
    }

    private struct MeshUniforms {
        var floorAlpha: Float
        var unused: Float = 0
    }

    private static let bandCount = DSPCardSpectrumFeed.bandCount
    /// Light-layer columns: the bands interpolated four times as finely.
    private static let columnCount = bandCount * 4
    /// Particle columns: one per pair of bands, wide enough to read apart.
    private static let emitterCount = bandCount / 2
    private static let particleCapacity = 4_096
    private static let slowdown: Float = 1.8
    /// Particles per second from one column at full level and mix 0.5.
    private static let maximumRate = 32.0
    /// How far the light rises with the live spectrum, in layer heights.
    private static let swell = 0.12
    private static let framesInFlight = 3
    /// Look follower slots.
    private static let featherSlot = 0
    private static let glowSlot = 1

    private let gpu = DSPReverbGPU.shared
    private var meshBuffers: [MTLBuffer] = []
    private var particleBuffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: DSPReverbVisualView.framesInFlight)

    private var heights: DSPFollowerBank
    private var emission: DSPFollowerBank
    /// Feather height and light strength, gliding with the parameters.
    private var lightLook: DSPFollowerBank
    /// 0…1 from the previous palette to the current one.
    private var colorBlend: DSPFollowerBank
    private var look: DSPReverbVisual.Look?
    private var layoutSpec = MotionTokens.standard[.layout]
    private var hasPlacedHeights = false
    private var isDark = false
    private var isActive = false
    private var paletteKey: [SIMD3<Float>]?
    private var emitterColors: [RGB] = []
    private var previousEmitterColors: [RGB] = []
    private var columnColors: [RGB] = []
    private var previousColumnColors: [RGB] = []

    private var particles: [Particle]
    private var nextParticle = 0
    /// Slots written since the last clear. Spawns fill from slot 0, so these
    /// are the only ones uploaded to the GPU and drawn.
    private var particleSlotsInUse = 0
    /// Emitter colours for the particle pass, rewritten in place each frame.
    private var tintScratch = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 1),
                                             count: DSPReverbVisualView.emitterCount)
    private var emissionCredit: [Double]
    private var inputBands = [Float](repeating: 0, count: DSPCardSpectrumFeed.bandCount)
    private var meshScratch: [MeshVertex]
    private var epoch: CFTimeInterval?
    private var lastFrameTime: CFTimeInterval?
    private var lastParticleDeath: CFTimeInterval = -.infinity
    private var random: UInt64 = 0x2545_F491_4F6C_DD1D
    private var holdsFeedLease = false

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override init(frame frameRect: NSRect) {
        let layout = MotionTokens.standard[.layout]
        heights = DSPFollowerBank(count: Self.bandCount, spec: layout, policy: .full)
        emission = DSPFollowerBank(count: Self.emitterCount, spec: CapsuleSpectrumDynamics.standard.motionSpec,
                                   policy: .full)
        lightLook = DSPFollowerBank(count: 2, spec: layout, policy: .full)
        colorBlend = DSPFollowerBank(count: 1, spec: layout, policy: .full, initialValue: 1)
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

    func configure(
        amounts: [Double],
        look: DSPReverbVisual.Look,
        palette: [NSColor],
        layoutSpec: MotionSpec,
        isDark: Bool,
        isActive: Bool
    ) {
        self.layoutSpec = layoutSpec
        heights.update(spec: layoutSpec, policy: motionPolicy)
        lightLook.update(spec: layoutSpec, policy: motionPolicy)
        colorBlend.update(spec: layoutSpec, policy: motionPolicy)
        let time = CACurrentMediaTime()
        for (band, amount) in amounts.prefix(Self.bandCount).enumerated() {
            heights.setTarget(amount, at: band, time: time)
        }
        // A bigger, longer room diffuses further above the bands; a wetter
        // one glows more strongly.
        lightLook.setTarget(0.14 + 0.3 * (0.5 * look.size + 0.5 * look.decay), at: Self.featherSlot, time: time)
        lightLook.setTarget(0.6 + 0.4 * look.mix.squareRoot(), at: Self.glowSlot, time: time)
        self.look = look
        if !hasPlacedHeights {
            heights.snapAll()
            lightLook.snapAll()
            hasPlacedHeights = true
        }
        updateColors(palette: palette, isDark: isDark, time: time)
        self.isActive = isActive
        wake()
    }

    func stopListening() {
        DSPCardSpectrumFeed.shared.cancelWake(owner: self)
        releaseFeed()
    }

    override func motionPolicyDidChange() {
        heights.update(spec: layoutSpec, policy: motionPolicy)
        lightLook.update(spec: layoutSpec, policy: motionPolicy)
        colorBlend.update(spec: layoutSpec, policy: motionPolicy)
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

    // MARK: Colours

    /// Spreads the palette across the frequency axis. A new palette, or a
    /// change of appearance, fades in over the light layer and particles alike.
    private func updateColors(palette: [NSColor], isDark: Bool, time: CFTimeInterval) {
        let srgb = palette.compactMap { $0.usingColorSpace(.sRGB) }
        let key = srgb.map { SIMD3(Float($0.redComponent), Float($0.greenComponent), Float($0.blueComponent)) }
        guard key != paletteKey || isDark != self.isDark || columnColors.isEmpty else { return }
        let hadColors = !columnColors.isEmpty
        let shownColumns = displayedColumnColors()
        let shownEmitters = displayedEmitterColors()
        paletteKey = key
        self.isDark = isDark

        let stops = Self.gradientStops(srgb).map { Self.tuned($0, isDark: isDark) }
        func color(at position: Double) -> RGB {
            guard !stops.isEmpty else {
                return DSPCardVisualColors(accent: .white, isDark: isDark).frequencyColor(position: position)
            }
            return Self.sample(stops, at: position)
        }
        emitterColors = (0..<Self.emitterCount).map { color(at: (Double($0) + 0.5) / Double(Self.emitterCount)) }
        // A continuous blend across the light layer, no steps between bands.
        columnColors = (0..<Self.columnCount).map { color(at: Double($0) / Double(Self.columnCount - 1)) }

        if hadColors {
            previousColumnColors = shownColumns
            previousEmitterColors = shownEmitters
            colorBlend.setTarget(0, at: 0, time: time)
            colorBlend.snapAll()
            colorBlend.setTarget(1, at: 0, time: time)
        }
    }

    /// Light-layer colours as currently drawn, mid-fade included.
    private func displayedColumnColors() -> [RGB] {
        displayedColors(current: columnColors, previous: previousColumnColors)
    }

    /// Particle colours per emitter as currently drawn, mid-fade included.
    private func displayedEmitterColors() -> [RGB] {
        displayedColors(current: emitterColors, previous: previousEmitterColors)
    }

    private func displayedColors(current: [RGB], previous: [RGB]) -> [RGB] {
        let blend = Float(min(1, max(0, colorBlend.value(0))))
        guard blend < 1, previous.count == current.count else { return current }
        return zip(previous, current).map { from, to in
            (from.red + (to.red - from.red) * blend,
             from.green + (to.green - from.green) * blend,
             from.blue + (to.blue - from.blue) * blend)
        }
    }

    /// Orders the swatches into a hue sweep that starts after the widest
    /// gap in hue, so neighbours blend without crossing the whole wheel.
    /// Near-neutral sets are ordered by lightness instead.
    private static func gradientStops(_ colors: [NSColor]) -> [OKColor.OKLCH] {
        let lch = colors.compactMap(OKColor.nsColorToOKLCH)
        guard lch.count > 1 else { return lch }
        guard lch.contains(where: { $0.c > 0.03 }) else { return lch.sorted { $0.l < $1.l } }
        let sorted = lch.sorted { $0.h < $1.h }
        var widest = 0
        var widestGap: CGFloat = -1
        for index in sorted.indices {
            let next = sorted[(index + 1) % sorted.count].h
            let gap = OKColor.normalizedHue(next - sorted[index].h)
            if gap > widestGap {
                widestGap = gap
                widest = index
            }
        }
        let start = (widest + 1) % sorted.count
        return (0..<sorted.count).map { sorted[(start + $0) % sorted.count] }
    }

    /// Night colours stay bright and day colours dark, whatever the artwork's
    /// own lightness. Hue and chroma still come from the artwork; the gamut
    /// mapping in `okLCHToNSColor` trims chroma that a tone cannot hold.
    private static func tuned(_ color: OKColor.OKLCH, isDark: Bool) -> OKColor.OKLCH {
        var result = color
        result.l = isDark ? min(max(color.l, 0.8), 0.95) : min(max(color.l, 0.28), 0.45)
        return result
    }

    private static func sample(_ stops: [OKColor.OKLCH], at position: Double) -> RGB {
        let scaled = min(max(position, 0), 1) * Double(stops.count - 1)
        let lower = min(stops.count - 1, Int(scaled.rounded(.down)))
        let upper = min(stops.count - 1, lower + 1)
        let mixed = OKColor.oklabLerp(stops[lower], stops[upper], t: CGFloat(scaled - Double(lower)))
        let color = OKColor.okLCHToNSColor(mixed, alpha: 1).usingColorSpace(.sRGB) ?? .white
        return (Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent))
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
        let lookMoving = lightLook.advance(to: time)
        let colorsMoving = colorBlend.advance(to: time)
        if sprays, dt > 0 { spawnParticles(at: time, dt: dt) }

        let particlesAlive = time < lastParticleDeath
        if !particlesAlive, epoch != nil {
            epoch = nil
            // Entries left from the last epoch would replay on the new clock
            // at their old birth times and colours. All are dead; clear the
            // slots in use so none survive.
            for index in 0..<particleSlotsInUse { particles[index] = Particle() }
            particleSlotsInUse = 0
            nextParticle = 0
        }
        draw(at: time)

        let keepRunning = heightsMoving || emissionMoving || lookMoving || colorsMoving || particlesAlive || hasSignal
        if !keepRunning {
            lastFrameTime = nil
            if sprays, isVisibleOnScreen {
                DSPCardSpectrumFeed.shared.wakeOnNextUpdate(owner: self) { [weak self] in self?.wake() }
            }
        }
        return keepRunning
    }

    private func spawnParticles(at time: CFTimeInterval, dt: CFTimeInterval) {
        guard let look, !emitterColors.isEmpty else { return }
        let start = epoch ?? time
        epoch = start
        let birth = Float(time - start)
        let columnWidth = 1 / Float(Self.emitterCount)
        // Wetter is denser; longer lives longer and climbs higher; bigger
        // is larger and sways more; wider fans further out.
        let rate = Self.maximumRate * (0.5 + look.mix)
        let baseLife = 0.9 + 2.0 * look.decay
        let climb = Float(0.55 + 0.45 * look.decay)
        let spread = Float(0.35 + 1.3 * look.width * (0.45 + 0.55 * look.size)) * columnWidth
        let sway = Float(0.2 + 0.45 * look.size) * columnWidth
        let baseSize = Float(1.0 + 1.4 * look.size)
        for emitter in 0..<Self.emitterCount {
            let strength = min(1, max(0, emission.value(emitter)))
            guard strength > 0.03 else {
                emissionCredit[emitter] = 0
                continue
            }
            // Rate grows faster than level, so loud bands clearly outspray quiet ones.
            emissionCredit[emitter] += pow(strength, 1.6) * rate * dt
            while emissionCredit[emitter] >= 1 {
                emissionCredit[emitter] -= 1
                let life = Float(baseLife) * (0.75 + 0.5 * nextRandom())
                // A long upper tail: a loud band sends a few past the top.
                let lift = nextRandom()
                let reach = Float(0.35 + 0.85 * strength) * climb * (0.6 + 0.9 * lift * lift)
                particles[nextParticle] = Particle(
                    x: (Float(emitter) + 0.5 + 0.6 * (nextRandom() - 0.5)) * columnWidth,
                    birth: birth - Float(dt) * nextRandom(),
                    speed: reach * Self.slowdown,
                    size: baseSize + 2 * Float(strength) * nextRandom(),
                    drift: (nextRandom() - 0.5) * 2 * spread,
                    life: life,
                    sway: (nextRandom() - 0.5) * 2 * sway,
                    phase: nextRandom() * 2 * Float.pi,
                    lane: Float(emitter)
                )
                nextParticle = (nextParticle + 1) % Self.particleCapacity
                particleSlotsInUse = min(Self.particleCapacity, particleSlotsInUse + 1)
                lastParticleDeath = max(lastParticleDeath, time + Double(life))
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
        // Only the slots in use are uploaded; the rest are empty.
        let particleCount = particleSlotsInUse
        if particleCount > 0 {
            particles.withUnsafeBytes { source in
                particleBuffer.contents().copyMemory(
                    from: source.baseAddress!, byteCount: particleCount * MemoryLayout<Particle>.stride)
            }
        }

        let look = look
        var uniforms = Uniforms(
            viewport: SIMD2(Float(bounds.width), Float(bounds.height)),
            time: Float(time - (epoch ?? time)),
            // A longer pre-delay holds each particle back before it shows.
            fadeIn: Float(0.06 + 0.3 * (look?.preDelay ?? 0)),
            slowdown: Self.slowdown,
            maxAlpha: isDark ? 0.85 : 0.75,
            scale: Float(metalLayer.contentsScale),
            // Large rooms sway slowly, small ones quickly.
            swayRate: Float(3.2 - 1.6 * (look?.size ?? 0.5))
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
        let glow = Float(lightLook.value(Self.glowSlot))
        var meshUniforms = MeshUniforms(floorAlpha: (isDark ? 0.34 : 0.3) * glow * (isActive ? 1 : 0.5))
        encoder.setRenderPipelineState(pipelines.mesh)
        encoder.setVertexBuffer(meshBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&meshUniforms, length: MemoryLayout<MeshUniforms>.stride, index: 0)
        // Body strip, then the feather strip above it.
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: Self.columnCount * 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: Self.columnCount * 2,
                               vertexCount: Self.columnCount * 2)

        if particleCount > 0 {
            for (index, color) in displayedEmitterColors().enumerated() {
                tintScratch[index] = SIMD4<Float>(color.red, color.green, color.blue, 1)
            }
            encoder.setRenderPipelineState(pipelines.particles)
            encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            tintScratch.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 2) }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: particleCount)
        }
        encoder.endEncoding()

        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Two neighbours and a cosine blend weight for one light-layer column.
    /// A curve through evenly spaced slots then has no corners between them.
    /// The table is fixed, so the mesh fill reads it instead of recomputing.
    private struct Tap {
        let lower: Int
        let upper: Int
        let blend: Double
    }

    private static func taps(count: Int) -> [Tap] {
        (0..<columnCount).map { column in
            let x = Double(column) / Double(columnCount - 1)
            let position = x * Double(count) - 0.5
            let lower = min(count - 1, max(0, Int(position.rounded(.down))))
            let upper = min(count - 1, lower + 1)
            let fraction = min(1, max(0, position - Double(lower)))
            return Tap(lower: lower, upper: upper, blend: (1 - cos(fraction * Double.pi)) / 2)
        }
    }

    private static let bandTaps = taps(count: bandCount)
    private static let emitterTaps = taps(count: emitterCount)

    private static func mix(_ a: Double, _ b: Double, _ blend: Double) -> Double {
        a * (1 - blend) + b * blend
    }

    /// Writes the light layer: a body strip from the floor to the band
    /// heights and a feather strip above it. The alpha slot carries the
    /// height in layer units (0, 1, 2); the fragment shader turns it into
    /// one smooth fade.
    private func fillMesh(into buffer: MTLBuffer) {
        let columns = Self.columnCount
        let feather = Float(lightLook.value(Self.featherSlot))
        let colors = displayedColumnColors()
        for column in 0..<columns {
            let x = Double(column) / Double(columns - 1)
            let band = Self.bandTaps[column]
            let emitter = Self.emitterTaps[column]
            let reverb = Self.mix(heights.value(band.lower), heights.value(band.upper), band.blend)
            // The light swells with what is playing, more where the band
            // receives more reverb.
            let live = Self.mix(emission.value(emitter.lower), emission.value(emitter.upper), emitter.blend)
            let amount = reverb + Self.swell * min(1, live) * (0.4 + 0.6 * reverb)
            let top = Float(1 - (0.06 + 0.7 * min(1, max(0, amount))))
            let color = colors.isEmpty ? (red: Float(1), green: Float(1), blue: Float(1)) : colors[column]
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
