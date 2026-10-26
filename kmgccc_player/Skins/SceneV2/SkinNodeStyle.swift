import MotionKit
import SwiftUI

/// `transition`: how a node enters and leaves as `visible` changes — `fade` (always), `scale`,
/// `blur`, `fromTop`, `fromBottom`, `fromLeading`, `fromTrailing`, joined with `+`. The node stays
/// mounted and animates on a motion token, so a change midway reverses smoothly.
/// Reduced motion keeps only the fade.
struct SkinVisibilityTransition: ViewModifier {
    let value: SkinValue
    let hidden: Bool
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var motionPolicy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let spec = SkinTransitionLook.spec(value)
        content
            .modifier(SkinTransitionLook(spec: spec, hidden: hidden, moves: motionPolicy.resolving(accessibilityReduceMotion: reduceMotion) == .full))
            .motionAnimation(SkinTransitionLook.animation(spec, tokens: motionTokens), value: hidden)
    }
}

/// The hidden look of a `transition`, without animation, so visibility and keyed swaps share it.
/// `direction` -1 mirrors the offset, for content that leaves the way new content arrives.
struct SkinTransitionLook: ViewModifier {
    let spec: SkinValue
    let hidden: Bool
    var moves = true
    var direction: Double = 1

    static func spec(_ value: SkinValue) -> SkinValue { value.type == .record ? value : .record(["type": value]) }
    static func animation(_ spec: SkinValue, tokens: MotionTokens) -> MotionSpec { SkinMotion.spec(spec, tokens: tokens) }

    func body(content: Content) -> some View {
        let kinds = Set(spec[member: "type"].textValue.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) })
        let moving = hidden && moves
        let distance = spec[member: "distance"].number(24) * direction
        let x = kinds.contains("fromLeading") ? -distance : kinds.contains("fromTrailing") ? distance : 0
        let y = kinds.contains("fromTop") ? -distance : kinds.contains("fromBottom") ? distance : 0
        let scale = moving && kinds.contains("scale") ? spec[member: "scale"].number(0.92) : 1
        // `glyphs`: arriving text clears from the blur one glyph at a time, in a scattered order;
        // leaving text keeps the whole-line look. Scene text reads the reveal from the environment
        // so it can combine it with its own glyph motion; host text takes the renderer directly.
        if kinds.contains("glyphs"), direction > 0, moves {
            let reveal = SkinGlyphReveal(progress: hidden ? 0 : 1, blur: spec[member: "blur"].number(8),
                                         stagger: spec[member: "stagger"].number(0.6).clamped01)
            content
                .environment(\.skinGlyphReveal, reveal)
                .textRenderer(SkinGlyphRenderer(reveal: reveal))
                .scaleEffect(scale)
                .offset(x: moving ? x : 0, y: moving ? y : 0)
        } else {
            content
                .opacity(hidden ? 0 : 1)
                .scaleEffect(scale)
                .blur(radius: moving && kinds.contains("blur") ? spec[member: "blur"].number(8) : 0)
                .offset(x: moving ? x : 0, y: moving ? y : 0)
        }
    }
}

/// The `glyphs` transition. Each glyph fades in from `blur` over its own share of the transition.
/// `stagger` is the part of the transition over which the glyphs' starts are spread; their order
/// is fixed per position.
struct SkinGlyphReveal: Equatable, Sendable {
    var progress: Double
    var blur: Double
    var stagger: Double
}

/// One glyph's `glyphMotion` result, around the glyph's centre. `split` separates red and blue
/// by that many points along x; `smearX`/`smearY` spread the glyph along a motion vector.
struct SkinGlyphTransform: Equatable, Sendable {
    var x = 0.0, y = 0.0, rotation = 0.0, scale = 1.0, opacity = 1.0, blur = 0.0
    var split = 0.0, smearX = 0.0, smearY = 0.0
    var tint: Color?

    init(_ value: SkinValue) {
        x = value[member: "x"].number(); y = value[member: "y"].number()
        rotation = value[member: "rotation"].number(); scale = value[member: "scale"].number(1)
        opacity = value[member: "opacity"].number(1).clamped01; blur = max(0, value[member: "blur"].number())
        split = value[member: "split"].number(); smearX = value[member: "smearX"].number(); smearY = value[member: "smearY"].number()
        tint = value[member: "tint"].colorValue?.swiftUIColor
    }
}

/// A flat colour a glyph copy is drawn in, keeping its coverage.
struct SkinGlyphInk: Equatable, Sendable {
    var red: Double, green: Double, blue: Double, alpha: Double

    init(_ color: OKLCHColor) {
        let resolved = ColorRenderingAdapter.resolve(color, target: .sRGB)
        red = resolved.red; green = resolved.green; blue = resolved.blue; alpha = resolved.alpha
    }

    var matrix: ColorMatrix {
        var matrix = ColorMatrix()
        matrix.r1 = 0; matrix.g2 = 0; matrix.b3 = 0
        matrix.r5 = Float(red); matrix.g5 = Float(green); matrix.b5 = Float(blue); matrix.a4 = Float(alpha)
        return matrix
    }
}

/// `outline`: a ring of `width` around each glyph; `hollow` keeps only the ring.
struct SkinGlyphOutline: Equatable, Sendable {
    var width: Double
    var ink: SkinGlyphInk
    var hollow: Bool

    init?(_ value: SkinValue?, fallback: OKLCHColor?) {
        guard let value, value.type != .null else { return nil }
        width = max(0.5, value.numberValue ?? value[member: "width"].number(1.5))
        ink = SkinGlyphInk(value[member: "color"].colorValue ?? fallback ?? OKLCHColor(lightness: 1, chroma: 0, hue: nil))
        hollow = value[member: "hollow"].isTruthy
    }
}

/// `extrude`: solid depth behind each glyph, `depth` points along `angle` degrees, drawn in
/// `color` fading toward `endColor`.
struct SkinGlyphExtrude: Equatable, Sendable {
    var depth: Double
    var dx: Double, dy: Double
    var near: SkinGlyphInk, far: SkinGlyphInk

    init?(_ value: SkinValue?, fallback: OKLCHColor?) {
        guard let value, value.type != .null else { return nil }
        depth = min(64, max(0, value.numberValue ?? value[member: "depth"].number(6)))
        guard depth > 0 else { return nil }
        let angle = value[member: "angle"].number(45) * .pi / 180
        dx = cos(angle); dy = sin(angle)
        let base = value[member: "color"].colorValue ?? fallback ?? OKLCHColor(lightness: 0.2, chroma: 0, hue: nil)
        near = SkinGlyphInk(base)
        far = SkinGlyphInk(value[member: "endColor"].colorValue ?? base)
    }
}

/// Per-glyph motion, outline and extrusion of one scene text, computed by the node on the main actor.
struct SkinGlyphStyle: Equatable, Sendable {
    var transforms: [SkinGlyphTransform] = []
    var outline: SkinGlyphOutline?
    var extrude: SkinGlyphExtrude?
    /// How far glyphs may draw outside the text's frame.
    var padding = 0.0
}

/// Draws scene text glyph by glyph: the `glyphs` reveal, `glyphMotion` and `outline` in one pass.
struct SkinGlyphRenderer: TextRenderer {
    var progress = 1.0
    var blur = 0.0
    var stagger = 0.0
    var reveals = false
    var style = SkinGlyphStyle()

    init(reveal: SkinGlyphReveal?, style: SkinGlyphStyle = .init()) {
        if let reveal { progress = reveal.progress; blur = reveal.blur; stagger = reveal.stagger; reveals = true }
        self.style = style
    }

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var displayPadding: EdgeInsets {
        let padding = style.padding + (reveals ? blur * 2 : 0)
        return EdgeInsets(top: padding, leading: padding, bottom: padding, trailing: padding)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var index = 0
        for line in layout {
            for run in line {
                for slice in run {
                    defer { index += 1 }
                    var opacity = 1.0, radius = 0.0
                    if reveals {
                        let start = stagger * Self.order(index)
                        let local = ((progress - start) / max(0.001, 1 - stagger)).clamped01
                        guard local > 0 else { continue }
                        opacity = local; radius = (1 - local) * blur
                    }
                    var glyph = context
                    let motion = index < style.transforms.count ? style.transforms[index] : nil
                    if let motion {
                        let bounds = slice.typographicBounds.rect
                        glyph.translateBy(x: bounds.midX + motion.x, y: bounds.midY + motion.y)
                        if motion.rotation != 0 { glyph.rotate(by: .degrees(motion.rotation)) }
                        if motion.scale != 1 { glyph.scaleBy(x: motion.scale, y: motion.scale) }
                        glyph.translateBy(x: -bounds.midX, y: -bounds.midY)
                        opacity *= motion.opacity; radius += motion.blur
                        if let tint = motion.tint { glyph.addFilter(.colorMultiply(tint)) }
                    }
                    guard opacity > 0.001 else { continue }
                    glyph.opacity *= opacity
                    if radius > 0.05 { glyph.addFilter(.blur(radius: radius)) }
                    Self.draw(slice, motion: motion, style: style, in: glyph)
                }
            }
        }
    }

    /// Extrusion behind, outline ring, then the face. Plain glyphs skip the offscreen layer.
    private static func draw(_ slice: Text.Layout.RunSlice, motion: SkinGlyphTransform?, style: SkinGlyphStyle, in context: GraphicsContext) {
        let split = motion?.split ?? 0
        let smear = CGSize(width: motion?.smearX ?? 0, height: motion?.smearY ?? 0)
        let smears = abs(smear.width) + abs(smear.height) > 0.25
        guard style.outline != nil || style.extrude != nil || abs(split) > 0.05 || smears else { context.draw(slice); return }
        context.drawLayer { layer in
            if let extrude = style.extrude {
                let steps = Int(min(32, ceil(extrude.depth)))
                for step in stride(from: steps, through: 1, by: -1) {
                    let fraction = Double(step) / Double(steps)
                    var copy = layer
                    copy.addFilter(.colorMatrix(mix(extrude.near, extrude.far, fraction).matrix))
                    copy.translateBy(x: extrude.dx * extrude.depth * fraction, y: extrude.dy * extrude.depth * fraction)
                    copy.draw(slice)
                }
            }
            if let outline = style.outline {
                var ring = layer
                ring.addFilter(.colorMatrix(outline.ink.matrix))
                let steps = outline.width > 2 ? 16 : 8
                for step in 0..<steps {
                    let angle = Double(step) / Double(steps) * 2 * .pi
                    var copy = ring
                    copy.translateBy(x: cos(angle) * outline.width, y: sin(angle) * outline.width)
                    copy.draw(slice)
                }
            }
            var face = layer
            if style.outline?.hollow == true { face.blendMode = .destinationOut }
            face.drawLayer { face in
                // A smear is the average of copies along the vector; additive copies at 1/n keep the coverage.
                let count = smears ? 6 : 1
                for step in 0..<count {
                    var copy = face
                    if smears {
                        let t = Double(step) / Double(count - 1) - 0.5
                        copy.blendMode = .plusLighter; copy.opacity = 1 / Double(count)
                        copy.translateBy(x: smear.width * t, y: smear.height * t)
                    }
                    drawFace(slice, split: split, in: copy)
                }
            }
        }
    }

    /// Red and blue drawn `split` points apart, green in place, summed back to the original colour.
    private static func drawFace(_ slice: Text.Layout.RunSlice, split: Double, in context: GraphicsContext) {
        guard abs(split) > 0.05 else { context.draw(slice); return }
        context.drawLayer { layer in
            for (channel, offset) in [(0, split), (1, 0.0), (2, -split)] {
                var copy = layer
                var matrix = ColorMatrix()
                matrix.r1 = channel == 0 ? 1 : 0; matrix.g2 = channel == 1 ? 1 : 0; matrix.b3 = channel == 2 ? 1 : 0
                copy.addFilter(.colorMatrix(matrix))
                copy.blendMode = .plusLighter
                copy.translateBy(x: offset, y: 0)
                copy.draw(slice)
            }
        }
    }

    private static func mix(_ a: SkinGlyphInk, _ b: SkinGlyphInk, _ t: Double) -> SkinGlyphInk {
        var ink = a
        ink.red += (b.red - a.red) * t; ink.green += (b.green - a.green) * t
        ink.blue += (b.blue - a.blue) * t; ink.alpha += (b.alpha - a.alpha) * t
        return ink
    }

    private static func order(_ index: Int) -> Double {
        let value = sin(Double(index) * 12.9898 + 78.233) * 43758.5453
        return value - floor(value)
    }
}

/// Wraps a scene text so its glyph style and any enclosing `glyphs` reveal draw in one renderer.
/// The innermost renderer wins, so this one replaces the reveal-only renderer of the transition.
struct SkinGlyphLayer<Content: View>: View {
    let style: SkinGlyphStyle?
    let content: Content
    @Environment(\.skinGlyphReveal) private var reveal

    var body: some View {
        if style != nil || reveal != nil {
            content.textRenderer(SkinGlyphRenderer(reveal: reveal, style: style ?? .init()))
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    @Entry var skinGlyphReveal: SkinGlyphReveal?
}

/// MotionKit for authors. An `animation` or `transition` names a token and may retune it with
/// duration, bounce and blendDuration, or replace it with a physical spring (stiffness, damping,
/// mass). `motion` on a node retunes tokens for its whole subtree, host components included:
/// `{"emphasis": {"duration": 0.5, "bounce": 0.3}, "speed": 1.2}`.
enum SkinMotion {
    static func tokens(_ base: MotionTokens, override value: SkinValue?) -> MotionTokens {
        guard let value, value.type == .record else { return base }
        var tokens = base
        let speed = max(0.05, value[member: "speed"].number(1))
        for token in MotionToken.allCases {
            let entry = value[member: token.rawValue]
            var spec = entry.type == .record ? tuned(entry, token: token, tokens: base) : tokens[token]
            if speed != 1, case .perceptual = spec.representation {
                spec = MotionSpec(duration: spec.duration / speed, bounce: spec.bounce, blendDuration: spec.blendDuration)
            }
            tokens[token] = spec
        }
        return tokens
    }

    static func spec(_ value: SkinValue, tokens: MotionTokens) -> MotionSpec {
        let name = value.type == .text ? value.textValue : value[member: "token"].textValue
        let token = MotionToken(rawValue: name) ?? .control
        return value.type == .record ? tuned(value, token: token, tokens: tokens) : tokens[token]
    }

    /// Explicit durations go through `phaseSpec`, so the user's motion speed still scales them.
    private static func tuned(_ value: SkinValue, token: MotionToken, tokens: MotionTokens) -> MotionSpec {
        let base = tokens[token]
        let blend = value[member: "blendDuration"].number(base.blendDuration)
        if value[member: "stiffness"].numberValue != nil {
            return MotionSpec(physical: .init(mass: value[member: "mass"].number(1), stiffness: value[member: "stiffness"].number(200),
                                              damping: value[member: "damping"].number(20)), blendDuration: blend)
        }
        guard case .perceptual = base.representation else { return base }
        guard let duration = value[member: "duration"].numberValue else {
            return MotionSpec(duration: base.duration, bounce: value[member: "bounce"].number(base.bounce), blendDuration: blend)
        }
        return tokens.phaseSpec(for: token, duration: duration, bounce: value[member: "bounce"].number(base.bounce), blendDuration: blend)
    }
}

/// `enter`: the node arrives with this transition when it first appears, after `delay` seconds.
/// On the scene root it is the skin's entrance when the skin is switched in.
struct SkinEnterTransition: ViewModifier {
    let value: SkinValue
    @State private var shown = false
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var motionPolicy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let spec = SkinTransitionLook.spec(value)
        content
            .modifier(SkinTransitionLook(spec: spec, hidden: !shown, moves: motionPolicy.resolving(accessibilityReduceMotion: reduceMotion) == .full))
            .onAppear {
                let animation = motionPolicy.resolvedAnimation(for: SkinTransitionLook.animation(spec, tokens: motionTokens), accessibilityReduceMotion: reduceMotion)
                withAnimation(animation?.delay(max(0, spec[member: "delay"].number()))) { shown = true }
            }
    }
}

/// `key`: when its value changes, the old content leaves and the new arrives with the node's
/// `transition` (a fade when none is given). The leaving copy moves the opposite way, so a
/// line that rises in from below pushes the previous one up. The leaving copy takes
/// `leaveDuration` (half of `duration` by default), so the old content never lingers.
struct SkinKeyedSwap: View {
    let key: String
    let transition: SkinValue
    let content: AnyView
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var motionPolicy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let spec = SkinTransitionLook.spec(transition.type == .null ? .text("fade") : transition)
        let moves = motionPolicy.resolving(accessibilityReduceMotion: reduceMotion) == .full
        let leave = Self.leaving(spec, enterDuration: SkinTransitionLook.animation(spec, tokens: motionTokens).duration)
        let enterAnimation = motionPolicy.resolvedAnimation(for: SkinTransitionLook.animation(spec, tokens: motionTokens), accessibilityReduceMotion: reduceMotion)
        let leaveAnimation = motionPolicy.resolvedAnimation(for: SkinTransitionLook.animation(leave, tokens: motionTokens), accessibilityReduceMotion: reduceMotion)
        ZStack {
            content.id(key).transition(.asymmetric(
                insertion: AnyTransition.modifier(active: SkinTransitionLook(spec: spec, hidden: true, moves: moves), identity: SkinTransitionLook(spec: spec, hidden: false)).animation(enterAnimation),
                removal: AnyTransition.modifier(active: SkinTransitionLook(spec: spec, hidden: true, moves: moves, direction: -1), identity: SkinTransitionLook(spec: spec, hidden: false)).animation(leaveAnimation)
            ))
        }
        .motionAnimation(SkinTransitionLook.animation(spec, tokens: motionTokens), value: key)
    }

    private static func leaving(_ spec: SkinValue, enterDuration: Double) -> SkinValue {
        guard case .record(var fields) = spec else { return spec }
        fields["duration"] = .number(spec[member: "leaveDuration"].number(enterDuration * 0.5))
        return .record(fields)
    }
}

enum SkinNodeStyle {
    static func apply(_ content: AnyView, values: [String: SkinValue], reduceTransparency: Bool) -> AnyView {
        var result = content
        let shape = SkinSceneShape(kind: values["glass"]?[member: "shape"].textValue ?? values["shape"]?.textValue ?? "rectangle", cornerRadius: values["cornerRadius"]?.number() ?? values["glass"]?[member: "cornerRadius"].number() ?? 0)
        if let color = values["background"]?.colorValue { result = AnyView(result.background(color.swiftUIColor, in: shape)) }
        if let material = values["material"]?.textValue {
            result = AnyView(result.background(materialStyle(material), in: shape))
        }
        if let glass = values["glass"] {
            result = AnyView(result.modifier(SkinGlassEffectModifier(value: glass, shape: shape)))
        }
        if let appGlass = values["appGlass"]?.textValue {
            result = AnyView(result.modifier(SkinAppGlassModifier(style: appGlass, shape: shape)))
        }
        if values["clip"]?.isTruthy == true || (values["cornerRadius"]?.number() ?? 0) > 0 { result = AnyView(result.clipShape(shape)) }
        if let border = values["border"], let color = border[member: "color"].colorValue {
            // An explicit author effect, rather than application chrome.
            result = AnyView(result.overlay(shape.stroke(color.swiftUIColor, lineWidth: border[member: "width"].number(1))))
        }
        // A list of shadows stacks them, nearest first.
        for shadow in values["shadow"].map({ $0.type == .list ? $0.listValue : [$0] }) ?? [] {
            result = AnyView(result.shadow(color: shadow[member: "color"].colorValue?.swiftUIColor ?? .clear, radius: shadow[member: "radius"].number(), x: shadow[member: "x"].number(), y: shadow[member: "y"].number()))
        }
        result = AnyView(result
            .opacity(values["opacity"]?.number(1) ?? 1)
            .rotationEffect(.degrees(values["rotation"]?.number() ?? 0))
            .scaleEffect(x: values["scaleX"]?.number() ?? values["scale"]?.number(1) ?? 1, y: values["scaleY"]?.number() ?? values["scale"]?.number(1) ?? 1)
            .offset(x: values["offsetX"]?.number() ?? 0, y: values["offsetY"]?.number() ?? 0)
            .blur(radius: max(0, values["blur"]?.number() ?? 0))
            .brightness(values["brightness"]?.number() ?? 0)
            .contrast(values["contrast"]?.number(1) ?? 1)
            .saturation(values["saturation"]?.number(1) ?? 1)
            .grayscale(values["grayscale"]?.number() ?? 0)
            .hueRotation(.degrees(values["hueRotation"]?.number() ?? 0))
            .blendMode(blendMode(values["blendMode"]?.textValue ?? "normal")))
        if values["invert"]?.isTruthy == true { result = AnyView(result.colorInvert()) }
        return result
    }

    static func materialStyle(_ name: String) -> Material {
        switch name {
        case "ultraThin": .ultraThinMaterial
        case "thin": .thinMaterial
        case "thick": .thickMaterial
        case "ultraThick": .ultraThickMaterial
        case "bar": .bar
        default: .regularMaterial
        }
    }

    static func blendMode(_ name: String) -> BlendMode {
        switch name {
        case "multiply": .multiply
        case "screen": .screen
        case "overlay": .overlay
        case "darken": .darken
        case "lighten": .lighten
        case "colorDodge": .colorDodge
        case "colorBurn": .colorBurn
        case "softLight": .softLight
        case "hardLight": .hardLight
        case "difference": .difference
        case "exclusion": .exclusion
        case "hue": .hue
        case "saturation": .saturation
        case "color": .color
        case "luminosity": .luminosity
        case "plusLighter": .plusLighter
        case "plusDarker": .plusDarker
        case "destinationOut": .destinationOut
        default: .normal
        }
    }
}

private struct SkinGlassEffectModifier: ViewModifier {
    let value: SkinValue
    let shape: SkinSceneShape
    @Environment(\.skinSceneGlassNamespace) private var namespace
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let name = value.type == .text ? value.textValue : value[member: "style"].textValue
        var style: Glass = name == "clear" ? .clear : name == "identity" ? .identity : .regular
        if let tint = value[member: "tint"].colorValue { style = style.tint(tint.swiftUIColor) }
        if value[member: "interactive"].isTruthy { style = style.interactive() }
        return Group {
            if reduceTransparency { content.background(.background, in: shape) }
            else if let namespace, !value[member: "id"].textValue.isEmpty {
                content.glassEffect(style, in: shape).glassEffectID(value[member: "id"].textValue, in: namespace)
            } else { content.glassEffect(style, in: shape) }
        }
    }
}

private struct SkinAppGlassModifier: ViewModifier {
    let style: String
    let shape: SkinSceneShape
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let material: LiquidGlassPillMaterialStyle = style == "clear" ? .clear : style == "normal" ? .normal : .regular
        content.background(GlassStyleTokens.pillOverlay(for: scheme, materialStyle: material), in: shape)
            .glassEffect(style == "clear" ? .clear : .regular, in: shape)
    }
}

extension EnvironmentValues {
    @Entry var skinSceneGlassNamespace: Namespace.ID?
}

nonisolated struct SkinSceneShape: Shape {
    var kind: String
    var points = ""
    var cornerRadius: Double = 0

    func path(in rect: CGRect) -> Path {
        switch kind {
        case "circle", "ellipse": return Ellipse().path(in: rect)
        case "capsule": return Capsule().path(in: rect)
        case "path": return svgPath(in: rect)
        default: return RoundedRectangle(cornerRadius: cornerRadius).path(in: rect)
        }
    }

    /// Unit-square path coordinates. The intentionally finite vocabulary has no execution.
    private func svgPath(in rect: CGRect) -> Path {
        let pattern = "[MLCQHVZmlcqhvz]|[-+]?(?:[0-9]*\\.)?[0-9]+(?:[eE][-+]?[0-9]+)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return Path() }
        let text = points as NSString
        let tokens = regex.matches(in: points, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range) }
        var result = Path(), index = 0, command = "", current = CGPoint.zero
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        while index < tokens.count {
            if Double(tokens[index]) == nil { command = tokens[index].uppercased(); index += 1 }
            if command == "Z" { result.closeSubpath(); command = ""; continue }
            let required = command == "C" ? 6 : command == "Q" ? 4 : ["H", "V"].contains(command) ? 1 : 2
            guard !command.isEmpty, index + required <= tokens.count else { break }
            let values = tokens[index..<(index + required)].compactMap(Double.init)
            guard values.count == required else { break }
            index += required
            switch command {
            case "M": current = point(values[0], values[1]); result.move(to: current); command = "L"
            case "L": current = point(values[0], values[1]); result.addLine(to: current)
            case "C": current = point(values[4], values[5]); result.addCurve(to: current, control1: point(values[0], values[1]), control2: point(values[2], values[3]))
            case "Q": current = point(values[2], values[3]); result.addQuadCurve(to: current, control: point(values[0], values[1]))
            case "H": current.x = rect.minX + values[0] * rect.width; result.addLine(to: current)
            case "V": current.y = rect.minY + values[0] * rect.height; result.addLine(to: current)
            default: break
            }
        }
        return result
    }
}
