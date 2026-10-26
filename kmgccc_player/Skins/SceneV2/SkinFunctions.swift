import AppKit
import Foundation

/// The fixed function table of the expression language: maths, interpolation, colour, text,
/// lists, time and the few data functions that take arguments (spectrum, lyric context).
struct SkinFunction {
    typealias Implementation = @MainActor ([SkinValue], SkinEvaluationContext) -> SkinValue

    let arity: ClosedRange<Int>
    let argumentTypes: [SkinValueType]
    let result: @MainActor ([SkinValueType]) -> SkinValueType
    var tier: SkinDataTier = .constant
    var domains: Set<SkinDataDomain> = []
    var capabilities: Set<String> = []
    let implementation: Implementation

    var arityDescription: String {
        arity.upperBound == Int.max ? "至少 \(arity.lowerBound)" :
            (arity.lowerBound == arity.upperBound ? "\(arity.lowerBound)" : "\(arity.lowerBound) 到 \(arity.upperBound)")
    }

    func argumentType(_ position: Int) -> SkinValueType {
        guard !argumentTypes.isEmpty else { return .any }
        return argumentTypes[min(position, argumentTypes.count - 1)]
    }

    func resultType(_ arguments: [SkinValueType]) -> SkinValueType { result(arguments) }
}

enum SkinFunctions {
    static let maximumGeneratedListCount = 1024

    static let table: [String: SkinFunction] = {
        var table: [String: SkinFunction] = [:]
        @MainActor func number(_ name: String, _ arity: ClosedRange<Int>, _ body: @escaping @MainActor ([Double]) -> Double) {
            table[name] = SkinFunction(arity: arity, argumentTypes: [.number], result: { _ in .number }) { arguments, _ in
                .number(SkinFunctions.sanitized(body(arguments.map { $0.number() })))
            }
        }

        // Maths
        number("abs", 1...1) { abs($0[0]) }
        number("floor", 1...1) { Foundation.floor($0[0]) }
        number("ceil", 1...1) { Foundation.ceil($0[0]) }
        number("round", 1...2) { $0.count == 2 && $0[1] > 0 ? ($0[0] / $0[1]).rounded() * $0[1] : $0[0].rounded() }
        number("sqrt", 1...1) { Foundation.sqrt(max(0, $0[0])) }
        number("pow", 2...2) { Foundation.pow($0[0], $0[1]) }
        number("exp", 1...1) { Foundation.exp($0[0]) }
        number("log", 1...1) { Foundation.log(max(1e-12, $0[0])) }
        number("log2", 1...1) { Foundation.log2(max(1e-12, $0[0])) }
        number("log10", 1...1) { Foundation.log10(max(1e-12, $0[0])) }
        number("sin", 1...1) { Foundation.sin($0[0]) }
        number("cos", 1...1) { Foundation.cos($0[0]) }
        number("tan", 1...1) { Foundation.tan($0[0]) }
        number("asin", 1...1) { Foundation.asin(min(1, max(-1, $0[0]))) }
        number("acos", 1...1) { Foundation.acos(min(1, max(-1, $0[0]))) }
        number("atan", 1...1) { Foundation.atan($0[0]) }
        number("atan2", 2...2) { Foundation.atan2($0[0], $0[1]) }
        number("sign", 1...1) { $0[0] > 0 ? 1 : ($0[0] < 0 ? -1 : 0) }
        number("fract", 1...1) { $0[0] - Foundation.floor($0[0]) }
        number("mod", 2...2) { $0[1] == 0 ? 0 : $0[0] - $0[1] * Foundation.floor($0[0] / $0[1]) }
        number("min", 1...Int.max) { $0.min() ?? 0 }
        number("max", 1...Int.max) { $0.max() ?? 0 }
        number("clamp", 3...3) { min(max($0[0], $0[1]), $0[2]) }
        number("deg", 1...1) { $0[0] * 180 / .pi }
        number("rad", 1...1) { $0[0] * .pi / 180 }
        number("step", 2...2) { $0[1] < $0[0] ? 0 : 1 }
        number("smoothstep", 3...3) { arguments in
            let range = arguments[1] - arguments[0]
            guard range != 0 else { return arguments[2] < arguments[0] ? 0 : 1 }
            let t = min(1, max(0, (arguments[2] - arguments[0]) / range))
            return t * t * (3 - 2 * t)
        }
        number("remap", 5...6) { arguments in
            let range = arguments[2] - arguments[1]
            var t = range == 0 ? 0 : (arguments[0] - arguments[1]) / range
            if arguments.count == 6, arguments[5] != 0 { t = min(1, max(0, t)) }
            return arguments[3] + (arguments[4] - arguments[3]) * t
        }
        // Easing over a 0…1 progress, clamped; `backOut` overshoots by its optional second argument.
        number("easeIn", 1...1) { let t = min(1, max(0, $0[0])); return t * t * t }
        number("easeOut", 1...1) { let t = 1 - min(1, max(0, $0[0])); return 1 - t * t * t }
        number("easeInOut", 1...1) { let t = min(1, max(0, $0[0])); return t < 0.5 ? 4 * t * t * t : 1 - Foundation.pow(-2 * t + 2, 3) / 2 }
        number("backOut", 1...2) { arguments in
            let t = min(1, max(0, arguments[0])) - 1, s = arguments.count == 2 ? arguments[1] : 1.70158
            return 1 + (s + 1) * t * t * t + s * t * t
        }
        number("random", 1...1) { SkinFunctions.hash01($0[0]) }
        number("noise", 1...1) { SkinFunctions.valueNoise($0[0]) }
        number("spring", 2...3) { arguments in
            // Damped oscillation from 1 towards 0 over `t`; useful for entrance motion.
            let t = max(0, arguments[0]), frequency = max(0.01, arguments[1])
            let damping = arguments.count == 3 ? max(0, arguments[2]) : 6
            return Foundation.exp(-damping * t) * Foundation.cos(2 * .pi * frequency * t)
        }

        table["mix"] = SkinFunction(arity: 3...3, argumentTypes: [.any, .any, .number], result: { types in
            types.first == .color || (types.count > 1 && types[1] == .color) ? .color : .number
        }) { arguments, _ in
            let t = arguments[2].number()
            if let a = arguments[0].colorValue, let b = arguments[1].colorValue,
               arguments[0].type == .color || arguments[1].type == .color {
                return .color(a.mixed(with: b, amount: t))
            }
            let a = arguments[0].number(), b = arguments[1].number()
            return .number(a + (b - a) * t)
        }
        table["lerp"] = table["mix"]

        // Time. These read the scene clock, so they make a property per-frame.
        table["spin"] = SkinFunction(arity: 1...2, argumentTypes: [.number], result: { _ in .number }, tier: .frame, domains: [.time]) { arguments, context in
            // Degrees for a turntable speed in revolutions per minute.
            let phase = arguments.count == 2 ? arguments[1].number() : 0
            return .number((context.time * arguments[0].number() * 6 + phase).truncatingRemainder(dividingBy: 360))
        }
        table["oscillate"] = SkinFunction(arity: 1...2, argumentTypes: [.number], result: { _ in .number }, tier: .frame, domains: [.time]) { arguments, context in
            let period = max(0.001, arguments[0].number())
            let phase = arguments.count == 2 ? arguments[1].number() : 0
            return .number(0.5 + 0.5 * Foundation.sin((context.time / period + phase) * 2 * .pi))
        }
        table["pulse"] = SkinFunction(arity: 1...1, argumentTypes: [.number], result: { _ in .number }, tier: .frame, domains: [.time]) { arguments, context in
            let period = max(0.001, arguments[0].number())
            return .number((context.time / period).truncatingRemainder(dividingBy: 1))
        }
        table["formatTime"] = SkinFunction(arity: 1...1, argumentTypes: [.number], result: { _ in .text }) { arguments, _ in
            let total = max(0, SkinValue.number(arguments[0].number().rounded(.down)).integer())
            let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
            return .text(hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds))
        }

        // Colour
        table["rgb"] = SkinFunction(arity: 3...4, argumentTypes: [.number], result: { _ in .color }) { arguments, _ in
            let values = arguments.map { $0.number() }
            return .color(.rgb(values[0], values[1], values[2], values.count == 4 ? values[3] : 1))
        }
        table["rgba"] = table["rgb"]
        table["oklch"] = SkinFunction(arity: 3...4, argumentTypes: [.number], result: { _ in .color }) { arguments, _ in
            let values = arguments.map { $0.number() }
            return .color(.oklch(values[0], values[1], values[2], values.count == 4 ? values[3] : 1))
        }
        table["hex"] = SkinFunction(arity: 1...1, argumentTypes: [.text], result: { _ in .color }) { arguments, _ in
            .color(OKLCHColor(named: arguments[0].textValue) ?? .black)
        }
        @MainActor func color(_ name: String, _ arity: ClosedRange<Int>, _ body: @escaping @MainActor (OKLCHColor, [Double]) -> SkinValue, result: SkinValueType = .color) {
            table[name] = SkinFunction(arity: arity, argumentTypes: [.color, .number], result: { _ in result }) { arguments, _ in
                body(arguments[0].colorValue ?? .black, arguments.dropFirst().map { $0.number() })
            }
        }
        color("alpha", 2...2) { .color($0.withAlpha($1[0])) }
        color("opacity", 2...2) { .color($0.withAlpha($0.alpha * $1[0])) }
        color("lighten", 2...2) { .color($0.adjusting(lightness: $1[0])) }
        color("darken", 2...2) { .color($0.adjusting(lightness: -$1[0])) }
        color("saturate", 2...2) { .color($0.adjusting(chromaScale: max(0, $1[0]))) }
        color("desaturate", 2...2) { .color($0.adjusting(chromaScale: max(0, 1 - $1[0]))) }
        color("rotateHue", 2...2) { .color($0.adjusting(hueDegrees: $1[0])) }
        color("withLightness", 2...2) { color, values in
            .color(OKLCHColor(lightness: values[0].clamped01, chroma: color.chroma, hue: color.hue, alpha: color.alpha))
        }
        color("withChroma", 2...2) { color, values in
            .color(OKLCHColor(lightness: color.lightness, chroma: max(0, values[0]), hue: color.hue, alpha: color.alpha))
        }
        color("contrast", 1...1) { color, _ in .color(color.contrastingForeground) }
        color("lightness", 1...1, { color, _ in .number(color.lightness) }, result: .number)
        color("chroma", 1...1, { color, _ in .number(color.chroma) }, result: .number)
        color("hue", 1...1, { color, _ in .number((color.hue ?? 0) * 360) }, result: .number)
        table["contrastRatio"] = SkinFunction(arity: 2...2, argumentTypes: [.color], result: { _ in .number }) { arguments, _ in
            .number(SkinFunctions.contrastRatio(arguments[0].colorValue ?? .black, arguments[1].colorValue ?? .white))
        }
        // The candidate (white and black by default) that reads best on the background.
        table["readable"] = SkinFunction(arity: 1...3, argumentTypes: [.color], result: { _ in .color }) { arguments, _ in
            let background = arguments[0].colorValue ?? .black
            let first = arguments.count > 1 ? arguments[1].colorValue ?? .white : .white
            let second = arguments.count > 2 ? arguments[2].colorValue ?? .black : .black
            return .color(SkinFunctions.contrastRatio(background, first) >= SkinFunctions.contrastRatio(background, second) ? first : second)
        }

        // Text
        @MainActor func text(_ name: String, _ arity: ClosedRange<Int>, _ body: @escaping @MainActor ([SkinValue]) -> SkinValue, result: SkinValueType = .text) {
            table[name] = SkinFunction(arity: arity, argumentTypes: [.any], result: { _ in result }) { arguments, _ in body(arguments) }
        }
        text("upper", 1...1) { .text($0[0].textValue.uppercased()) }
        text("lower", 1...1) { .text($0[0].textValue.lowercased()) }
        text("trim", 1...1) { .text($0[0].textValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
        text("str", 1...1) { .text($0[0].textValue) }
        text("concat", 1...Int.max) { .text($0.map(\.textValue).joined()) }
        text("format", 2...2) { arguments in
            .text(String(format: "%.\(max(0, min(6, arguments[1].integer())))f", arguments[0].number()))
        }
        text("replace", 3...3) { .text($0[0].textValue.replacingOccurrences(of: $0[1].textValue, with: $0[2].textValue)) }
        text("substring", 2...3) { arguments in
            let characters = Array(arguments[0].textValue)
            let start = min(characters.count, max(0, arguments[1].integer()))
            let length = arguments.count == 3 ? max(0, arguments[2].integer()) : characters.count - start
            return .text(String(characters[start..<min(characters.count, start + length)]))
        }
        text("contains", 2...2, { arguments in
            if case .list(let items) = arguments[0] { return .boolean(items.contains { SkinFunctions.looselyEqual($0, arguments[1]) }) }
            return .boolean(arguments[0].textValue.contains(arguments[1].textValue))
        }, result: .boolean)
        text("split", 2...2, { arguments in
            .list(arguments[0].textValue.components(separatedBy: arguments[1].textValue)
                .prefix(SkinFunctions.maximumGeneratedListCount).map { SkinValue.text($0) })
        }, result: .list)
        text("join", 2...2) { .text($0[0].listValue.map(\.textValue).joined(separator: $0[1].textValue)) }

        // Lists
        text("count", 1...1, { arguments in
            switch arguments[0] {
            case .list(let items): return .number(Double(items.count))
            case .text(let value): return .number(Double(value.count))
            case .record(let fields): return .number(Double(fields.count))
            default: return .number(0)
            }
        }, result: .number)
        table["length"] = table["count"]
        text("at", 2...2, { $0[0][index: SkinValue.number($0[1].number().rounded(.down)).integer()] }, result: .any)
        text("first", 1...1, { $0[0][index: 0] }, result: .any)
        text("last", 1...1, { $0[0][index: -1] }, result: .any)
        text("slice", 2...3, { arguments in
            let items = arguments[0].listValue
            let start = min(items.count, max(0, arguments[1].integer()))
            let count = arguments.count == 3 ? max(0, arguments[2].integer()) : items.count - start
            return .list(Array(items[start..<min(items.count, start + count)]))
        }, result: .list)
        text("reverse", 1...1, { .list($0[0].listValue.reversed()) }, result: .list)
        text("range", 1...3, { arguments in
            let start = arguments.count >= 2 ? arguments[0].number() : 0
            let end = arguments.count >= 2 ? arguments[1].number() : arguments[0].number()
            let step = arguments.count == 3 ? arguments[2].number() : 1
            guard step != 0 else { return .list([]) }
            var values: [SkinValue] = []
            var value = start
            while (step > 0 ? value < end : value > end), values.count < SkinFunctions.maximumGeneratedListCount {
                values.append(.number(value)); value += step
            }
            return .list(values)
        }, result: .list)
        text("sum", 1...1, { .number($0[0].listValue.reduce(0) { $0 + $1.number() }) }, result: .number)
        text("average", 1...1, { arguments in
            let items = arguments[0].listValue
            return .number(items.isEmpty ? 0 : items.reduce(0) { $0 + $1.number() } / Double(items.count))
        }, result: .number)
        text("maxOf", 1...1, { .number($0[0].listValue.map { $0.number() }.max() ?? 0) }, result: .number)
        text("minOf", 1...1, { .number($0[0].listValue.map { $0.number() }.min() ?? 0) }, result: .number)
        text("indexOf", 2...2, { arguments in
            .number(Double(arguments[0].listValue.firstIndex { SkinFunctions.looselyEqual($0, arguments[1]) } ?? -1))
        }, result: .number)
        text("keys", 1...1, { arguments in
            guard case .record(let fields) = arguments[0] else { return .list([]) }
            return .list(fields.keys.sorted().map { .text($0) })
        }, result: .list)
        // Running sums, inclusive; `offsets` gives each item's start with `gap` between items.
        text("cumsum", 1...1, { arguments in
            var total = 0.0
            return .list(arguments[0].listValue.map { total += $0.number(); return .number(total) })
        }, result: .list)
        text("offsets", 1...2, { arguments in
            let gap = arguments.count == 2 ? arguments[1].number() : 0
            var total = 0.0
            return .list(arguments[0].listValue.map { item in defer { total += item.number() + gap }; return .number(total) })
        }, result: .list)
        text("pluck", 2...2, { arguments in .list(arguments[0].listValue.map { $0[member: arguments[1].textValue] }) }, result: .list)
        text("argmax", 1...1, { arguments in
            let items = arguments[0].listValue.map { $0.number() }
            return .number(Double(items.indices.max { items[$0] < items[$1] } ?? -1))
        }, result: .number)
        text("argmin", 1...1, { arguments in
            let items = arguments[0].listValue.map { $0.number() }
            return .number(Double(items.indices.min { items[$0] < items[$1] } ?? -1))
        }, result: .number)
        // Element-wise arithmetic over a list and a number or a list of the same length.
        @MainActor func elementwise(_ name: String, _ body: @escaping (Double, Double) -> Double) {
            text(name, 2...2, { arguments in
                let left = arguments[0].listValue, right = arguments[1]
                return .list(left.indices.map { index in
                    .number(SkinFunctions.sanitized(body(left[index].number(), right.type == .list ? right[index: index].number() : right.number())))
                })
            }, result: .list)
        }
        elementwise("addEach") { $0 + $1 }
        elementwise("mulEach") { $0 * $1 }

        // Text measurement, in points, with the system font or a family loaded by the package.
        // Change tier, so a package font that registers after compilation is still measured.
        table["measureText"] = SkinFunction(arity: 2...4, argumentTypes: [.any], result: { _ in .number }, tier: .change) { arguments, _ in
            .number(SkinTextMeasure.width(arguments[0].textValue, size: arguments[1].number(), weight: arguments.count > 2 ? arguments[2].textValue : "",
                                          font: arguments.count > 3 ? arguments[3].textValue : ""))
        }
        // One width per item; items are texts or records with `text`.
        table["measureEach"] = SkinFunction(arity: 2...4, argumentTypes: [.any], result: { _ in .list }, tier: .change) { arguments, _ in
            let weight = arguments.count > 2 ? arguments[2].textValue : "", font = arguments.count > 3 ? arguments[3].textValue : ""
            return .list(arguments[0].listValue.prefix(SkinFunctions.maximumGeneratedListCount).map { item in
                let text = item.type == .record ? item[member: "text"].textValue : item.textValue
                return .number(SkinTextMeasure.width(text, size: arguments[1].number(), weight: weight, font: font))
            })
        }

        // Logic
        table["if"] = SkinFunction(arity: 3...3, argumentTypes: [.any], result: { types in types[1] == types[2] ? types[1] : .any }) { arguments, _ in
            arguments[0].isTruthy ? arguments[1] : arguments[2]
        }
        text("isNull", 1...1, { arguments in
            if case .null = arguments[0] { return .boolean(true) }
            return .boolean(false)
        }, result: .boolean)
        table["default"] = SkinFunction(arity: 2...2, argumentTypes: [.any], result: { types in types[0] == types[1] ? types[0] : .any }) { arguments, _ in
            if case .null = arguments[0] { return arguments[1] }
            return arguments[0]
        }
        table["has"] = SkinFunction(arity: 1...1, argumentTypes: [.text], result: { _ in .boolean }) { arguments, _ in
            .boolean(SkinHostCapabilities.all.contains(arguments[0].textValue))
        }

        // Viewport units
        @MainActor func viewport(_ name: String, _ body: @escaping (CGSize) -> Double) {
            table[name] = SkinFunction(arity: 1...1, argumentTypes: [.number], result: { _ in .number }, tier: .change, domains: [.viewport], capabilities: ["viewport@1"]) { arguments, context in
                .number(arguments[0].number() / 100 * body(context.live?.size ?? context.data.viewportSize))
            }
        }
        viewport("vw") { $0.width }
        viewport("vh") { $0.height }
        viewport("vmin") { min($0.width, $0.height) }
        viewport("vmax") { max($0.width, $0.height) }

        // Data that takes arguments
        table["spectrum"] = SkinFunction(
            arity: 1...3, argumentTypes: [.number], result: { _ in .list },
            tier: .frame, domains: [.audio], capabilities: ["audio.spectrum@1"]
        ) { arguments, context in
            let count = min(256, max(1, arguments[0].integer()))
            let low = arguments.count >= 2 ? arguments[1].number() : 30
            let high = arguments.count >= 3 ? arguments[2].number() : 16_000
            return .list(context.data.spectrum(count: count, lowHz: low, highHz: high, now: context.now).map { .number($0) })
        }
        table["waveform"] = SkinFunction(
            arity: 1...1, argumentTypes: [.number], result: { _ in .list },
            tier: .frame, domains: [.audio], capabilities: ["audio.raw@1"]
        ) { arguments, context in
            .list(context.data.waveform(count: min(1024, max(2, arguments[0].integer()))).map { .number($0) })
        }
        table["band"] = SkinFunction(
            arity: 2...2, argumentTypes: [.number], result: { _ in .number },
            tier: .frame, domains: [.audio], capabilities: ["audio.bands@1"]
        ) { arguments, context in
            .number(context.data.band(lowHz: arguments[0].number(), highHz: arguments[1].number(), now: context.now))
        }
        table["lyricLine"] = SkinFunction(
            arity: 1...1, argumentTypes: [.number], result: { _ in .record },
            tier: .frame, domains: [.lyrics, .lyricsTimeline], capabilities: ["lyrics.derived@1"]
        ) { arguments, context in
            context.data.lyricLine(relative: SkinValue.number(arguments[0].number().rounded()).integer(), now: context.now)
        }
        table["lyricAt"] = SkinFunction(
            arity: 1...1, argumentTypes: [.number], result: { _ in .record },
            tier: .change, domains: [.lyrics], capabilities: ["lyrics.document@1"]
        ) { arguments, context in
            context.data.value(forKey: "lyrics.lines", domain: .lyrics, now: context.now)[index: SkinValue.number(arguments[0].number().rounded()).integer()]
        }
        table["lyricProgress"] = SkinFunction(
            arity: 1...1, argumentTypes: [.number], result: { _ in .number },
            tier: .frame, domains: [.lyrics, .lyricsTimeline], capabilities: ["lyrics.derived@1"]
        ) { arguments, context in
            .number(context.data.lyricProgress(index: SkinValue.number(arguments[0].number().rounded()).integer(), now: context.now))
        }
        table["lyricTime"] = SkinFunction(
            arity: 1...1, argumentTypes: [.number], result: { _ in .number },
            tier: .change, domains: [.lyrics], capabilities: ["lyrics.document@1"]
        ) { arguments, context in
            // Start of a line in playback seconds, for seek actions.
            let line = context.data.value(forKey: "lyrics.lines", domain: .lyrics, now: context.now)[index: SkinValue.number(arguments[0].number().rounded()).integer()]
            return .number(line[member: "start"].number() + context.data.clock.seekOffset)
        }
        return table
    }()

    static func sanitized(_ value: Double) -> Double { value.isFinite ? value : 0 }
}

/// Typographic widths for `measureText`, cached because lyric layouts ask for the same words
/// every time they change.
@MainActor
enum SkinTextMeasure {
    private static var cache: [String: Double] = [:]

    static func width(_ text: String, size: Double, weight: String, font name: String) -> Double {
        guard !text.isEmpty, size > 0 else { return 0 }
        let key = "\(name)|\(weight)|\(size)|\(text)"
        if let width = cache[key] { return width }
        let named = name.isEmpty ? nil : NSFont(name: name, size: size)
        let font = named ?? NSFont.systemFont(ofSize: size, weight: Self.weight(weight))
        let width = Double((text as NSString).size(withAttributes: [.font: font]).width)
        // A package font may not be registered yet; measure it again once it is.
        guard name.isEmpty || named != nil else { return width }
        if cache.count > 4096 { cache.removeAll(keepingCapacity: true) }
        cache[key] = width
        return width
    }

    private static func weight(_ name: String) -> NSFont.Weight {
        switch name {
        case "ultralight": .ultraLight
        case "light": .light
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        case "heavy": .heavy
        case "black": .black
        default: .regular
        }
    }
}

extension SkinFunctions {

    static func hash01(_ value: Double) -> Double {
        var x = (value * 1000).rounded().bitPattern
        x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
        x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
        x ^= x >> 31
        return Double(x % 1_000_000) / 1_000_000
    }

    static func valueNoise(_ x: Double) -> Double {
        let i = Foundation.floor(x), f = x - i
        let u = f * f * (3 - 2 * f)
        return hash01(i) + (hash01(i + 1) - hash01(i)) * u
    }

    /// WCAG contrast ratio, alpha ignored.
    static func contrastRatio(_ a: OKLCHColor, _ b: OKLCHColor) -> Double {
        Double(RenderedBackdropReadability.contrastRatio(foregroundLuma: ColorMath.relativeLuminance(of: a.nsColor),
                                                         backgroundLuma: ColorMath.relativeLuminance(of: b.nsColor)))
    }

    static func looselyEqual(_ a: SkinValue, _ b: SkinValue) -> Bool {
        switch (a, b) {
        case (.number, .boolean), (.boolean, .number), (.number, .number): return a.number() == b.number()
        case (.color(let x), .color(let y)): return x.hexString == y.hexString
        default: return a == b
        }
    }
}
