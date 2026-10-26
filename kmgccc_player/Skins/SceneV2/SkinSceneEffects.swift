import MotionKit
import SwiftUI

/// `filter`: shader effects over the node's rendered subtree, applied in order: the built-in
/// presets, or `custom` functions from a precompiled `.metallib` in the package.
/// The node is padded by each filter's reach first, so offsets and glows are not cut at its frame.
/// Moving presets keep their own display timeline around the effect only, so the subtree is not
/// rebuilt per frame. Reduced motion drops glitch and wave; a dormant node keeps its effects off.
struct SkinSceneFilters: ViewModifier {
    let filters: [SkinValue]
    var dormant = false
    @Environment(\.skinSceneIsActive) private var active
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionPolicy) private var motionPolicy
    @Environment(\.skinPackageResources) private var root

    func body(content: Content) -> some View {
        let moves = motionPolicy.resolving(accessibilityReduceMotion: reduceMotion) == .full
        let animated = moves && filters.contains { filter in
            switch filter[member: "type"].textValue {
            case "glitch", "grain", "wave": true
            case "scanlines": filter[member: "speed"].number() != 0
            case "custom": filter[member: "animated"].isTruthy
            default: false
            }
        }
        TimelineView(.animation(minimumInterval: nil, paused: !animated || !active || dormant)) { timeline in
            Self.apply(AnyView(content), filters: filters, time: timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600),
                       moves: moves, enabled: !dormant, root: root)
        }
    }

    private static func apply(_ content: AnyView, filters: [SkinValue], time: Double, moves: Bool, enabled: Bool, root: URL?) -> AnyView {
        var view = content
        let library = ShaderLibrary.default
        for filter in filters {
            switch filter[member: "type"].textValue {
            case "chromatic":
                let amount = filter[member: "amount"].number(2)
                let shader = library.skinFxChromatic(.float(amount), .float(filter[member: "angle"].number() * .pi / 180))
                view = padded(view, reach: abs(amount)) { $0.layerEffect(shader, maxSampleOffset: CGSize(width: abs(amount), height: abs(amount)), isEnabled: enabled) }
            case "glitch" where moves:
                let amount = filter[member: "amount"].number(12)
                let shader = library.skinFxGlitch(.float(time), .float(amount), .float(filter[member: "slice"].number(6)),
                                                  .float(filter[member: "rate"].number(8)), .float(filter[member: "intensity"].number(0.3).clamped01))
                view = padded(view, reach: abs(amount) * 1.2) { $0.layerEffect(shader, maxSampleOffset: CGSize(width: abs(amount) * 1.2, height: 0), isEnabled: enabled) }
            case "motionBlur":
                let x = filter[member: "x"].number(), y = filter[member: "y"].number()
                let reach = max(abs(x), abs(y)) / 2
                let shader = library.skinFxMotionBlur(.float2(x, y), .float(filter[member: "samples"].number(12)))
                view = padded(view, reach: reach) { $0.layerEffect(shader, maxSampleOffset: CGSize(width: abs(x) / 2, height: abs(y) / 2), isEnabled: enabled && reach > 0.25) }
            case "scanlines":
                let shader = library.skinFxScanlines(.float(time), .float(filter[member: "spacing"].number(3)),
                                                     .float(filter[member: "intensity"].number(0.25).clamped01), .float(moves ? filter[member: "speed"].number() : 0))
                view = AnyView(view.colorEffect(shader, isEnabled: enabled))
            case "grain":
                view = AnyView(view.colorEffect(library.skinFxGrain(.float(moves ? time : 0), .float(filter[member: "amount"].number(0.08))), isEnabled: enabled))
            case "wave" where moves:
                let amplitude = filter[member: "amplitude"].number(4)
                let shader = library.skinFxWave(.float(time), .float(amplitude), .float(filter[member: "wavelength"].number(180)), .float(filter[member: "speed"].number(1.5)))
                view = padded(view, reach: abs(amplitude)) { $0.distortionEffect(shader, maxSampleOffset: CGSize(width: abs(amplitude), height: abs(amplitude)), isEnabled: enabled) }
            case "custom":
                view = custom(view, filter: filter, time: moves ? time : 0, enabled: enabled, root: root)
            default: break
            }
        }
        return view
    }

    /// A package's own `[[stitchable]]` function. After SwiftUI's own arguments it receives
    /// `float2 size` (the padded canvas) and `float time`, then `args` in order: numbers as float,
    /// lists of 2 to 4 numbers as float2 to float4, colours as half4.
    private static func custom(_ view: AnyView, filter: SkinValue, time: Double, enabled: Bool, root: URL?) -> AnyView {
        guard let library = SkinShaderLibraries.library(filter[member: "library"].textValue, root: root) else { return view }
        let function = ShaderFunction(library: library, name: filter[member: "function"].textValue)
        let arguments = filter[member: "args"].listValue.map(SkinShaderLibraries.argument)
        let reach = max(0, filter[member: "reach"].number())
        let offset = CGSize(width: reach, height: reach)
        switch filter[member: "kind"].textValue {
        case "color":
            return AnyView(view.visualEffect { effect, proxy in
                effect.colorEffect(Shader(function: function, arguments: [.float2(proxy.size), .float(time)] + arguments), isEnabled: enabled)
            })
        case "distortion":
            return padded(view, reach: reach) { padded in
                padded.visualEffect { effect, proxy in
                    effect.distortionEffect(Shader(function: function, arguments: [.float2(proxy.size), .float(time)] + arguments), maxSampleOffset: offset, isEnabled: enabled)
                }
            }
        default:
            return padded(view, reach: reach) { padded in
                padded.visualEffect { effect, proxy in
                    effect.layerEffect(Shader(function: function, arguments: [.float2(proxy.size), .float(time)] + arguments), maxSampleOffset: offset, isEnabled: enabled)
                }
            }
        }
    }

    /// Grows the effect's canvas by `reach` without changing the node's layout.
    static func padded(_ view: AnyView, reach: Double, effect: (AnyView) -> some View) -> AnyView {
        let reach = ceil(max(0, reach))
        guard reach > 0 else { return AnyView(effect(view)) }
        return AnyView(effect(AnyView(view.padding(reach))).padding(-reach))
    }
}

/// Precompiled package shader libraries, loaded once per file.
@MainActor
enum SkinShaderLibraries {
    private static var loaded: [URL: ShaderLibrary] = [:]

    static func library(_ path: String, root: URL?) -> ShaderLibrary? {
        guard path.hasSuffix(".metallib"), let root, let url = try? SkinResourceResolver.resolve(path, root: root) else { return nil }
        if let library = loaded[url] { return library }
        let library = ShaderLibrary(url: url)
        loaded[url] = library
        return library
    }

    static func argument(_ value: SkinValue) -> Shader.Argument {
        if let color = value.colorValue, value.type == .color { return .color(color.swiftUIColor) }
        let numbers = value.listValue.map { Float($0.number()) }
        switch numbers.count {
        case 2: return .float2(numbers[0], numbers[1])
        case 3: return .float3(numbers[0], numbers[1], numbers[2])
        case 4: return .float4(numbers[0], numbers[1], numbers[2], numbers[3])
        default: return .float(Float(value.number()))
        }
    }
}

/// `bloom`: bright parts of the subtree glow by `radius`, added onto it like plusLighter.
struct SkinSceneBloom: ViewModifier {
    let value: SkinValue
    var dormant = false

    func body(content: Content) -> some View {
        let radius = max(1, value.numberValue ?? value[member: "radius"].number(16))
        let intensity = value[member: "intensity"].number(0.8)
        let shader = ShaderLibrary.default.skinFxBloom(.float(radius), .float(intensity), .float(value[member: "threshold"].number().clamped01))
        SkinSceneFilters.padded(AnyView(content), reach: radius) {
            $0.layerEffect(shader, maxSampleOffset: CGSize(width: radius, height: radius), isEnabled: !dormant && intensity > 0.001)
        }
    }
}

/// `fog`: domain-warped fbm between two colours, drawn at a third of the resolution and scaled up;
/// the noise is soft, so the loss does not show.
struct SkinSceneFog: View {
    let low: Color
    let high: Color
    let time: Double
    let feature: Double
    let speed: Double
    let warp: Double
    let gain: Double
    private let reduction = 3.0

    var body: some View {
        GeometryReader { proxy in
            let size = CGSize(width: max(1, proxy.size.width / reduction), height: max(1, proxy.size.height / reduction))
            Rectangle().fill(.white)
                .frame(width: size.width, height: size.height)
                .colorEffect(ShaderLibrary.default.skinFxFog(.float(time), .float(max(1, feature) / reduction), .float(speed), .float(warp), .float(gain), .color(low), .color(high)))
                .scaleEffect(reduction, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}

/// `camera` on a layer: it looks at layer point centre + (`x`, `y`) and zooms by `zoom`, both
/// scaled by `1 / (1 + depth)`, so far children move less. The pan is in layer points before the
/// zoom, so a camera can follow content laid out in layer coordinates. Rotations turn the whole layer.
nonisolated struct SkinSceneCamera: Equatable, Sendable {
    var x: Double, y: Double, zoom: Double
    var rotation: Double, rotationX: Double, rotationY: Double, perspective: Double

    @MainActor init(_ value: SkinValue) {
        x = value[member: "x"].number(); y = value[member: "y"].number(); zoom = max(0.05, value[member: "zoom"].number(1))
        rotation = value[member: "rotation"].number(); rotationX = value[member: "rotationX"].number(); rotationY = value[member: "rotationY"].number()
        perspective = value[member: "perspective"].number(0.5)
    }

    /// The child's centre and scale after the camera, for a child at `depth`.
    func place(_ point: CGPoint, depth: Double, in size: CGSize) -> (point: CGPoint, scale: Double) {
        let factor = 1 / (1 + max(-0.9, depth))
        let scale = 1 + (zoom - 1) * factor
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        return (CGPoint(x: centre.x + (point.x - centre.x - x * factor) * scale, y: centre.y + (point.y - centre.y - y * factor) * scale), scale)
    }
}

/// Evaluates a per-frame camera at most once per display frame, for every child that asks.
@MainActor
final class SkinCameraSource {
    var evaluate: @MainActor (Double) -> SkinSceneCamera = { _ in SkinSceneCamera(.null) }
    var pausesWithPlayback = true
    private var cached: (now: Double, camera: SkinSceneCamera)?

    func camera(at now: Double) -> SkinSceneCamera {
        if let cached, cached.now == now { return cached.camera }
        let camera = evaluate(now)
        cached = (now, camera)
        return camera
    }
}

/// What a layer hands its children: a camera that changes only with data (`steady`), or the
/// source to ask each frame. The source is compared by identity, so per-frame motion never
/// re-renders the children themselves.
struct SkinCameraLink: Equatable {
    let source: SkinCameraSource
    let steady: SkinSceneCamera?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.source === rhs.source && lhs.steady == rhs.steady }
}

/// Moves one positioned child with its layer's camera: geometry only, on a timeline that wraps
/// the transform and not the child.
struct SkinCameraFollow: ViewModifier {
    let link: SkinCameraLink
    let centre: CGPoint
    let depth: Double
    let size: CGSize
    let paused: Bool

    func body(content: Content) -> some View {
        if let steady = link.steady {
            place(content, camera: steady)
        } else {
            TimelineView(.animation(minimumInterval: nil, paused: paused)) { timeline in
                place(content, camera: link.source.camera(at: timeline.date.timeIntervalSinceReferenceDate))
            }
        }
    }

    private func place(_ content: Content, camera: SkinSceneCamera) -> some View {
        let placed = camera.place(centre, depth: depth, in: size)
        return content.scaleEffect(placed.scale).offset(x: placed.point.x - centre.x, y: placed.point.y - centre.y)
    }
}

/// Turns a camera layer as a whole.
struct SkinCameraTurn: ViewModifier {
    let link: SkinCameraLink
    let paused: Bool

    func body(content: Content) -> some View {
        if let steady = link.steady {
            turn(content, camera: steady)
        } else {
            TimelineView(.animation(minimumInterval: nil, paused: paused)) { timeline in
                turn(content, camera: link.source.camera(at: timeline.date.timeIntervalSinceReferenceDate))
            }
        }
    }

    private func turn(_ content: Content, camera: SkinSceneCamera) -> some View {
        content
            .rotation3DEffect(.degrees(camera.rotationX), axis: (x: 1, y: 0, z: 0), perspective: camera.perspective)
            .rotation3DEffect(.degrees(camera.rotationY), axis: (x: 0, y: 1, z: 0), perspective: camera.perspective)
            .rotationEffect(.degrees(camera.rotation))
    }
}

/// Plain texts with `glyphMotion` time their glyphs from when the text last changed. A reference
/// type, so the renderer can restart the clock in the same frame the text changes.
final class SkinGlyphClock {
    private var key: String?
    private var start = 0.0

    func start(for key: String, now: Double) -> Double {
        if key != self.key { self.key = key; start = now }
        return start
    }
}
