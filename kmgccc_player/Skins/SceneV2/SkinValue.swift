import AppKit
import SwiftUI

/// Values of the scene language. Colours stay perceptual (OKLCH) until a view draws them,
/// so mixing and lightness changes behave the same on every display.
enum SkinValue: Equatable {
    case null
    case boolean(Bool)
    case number(Double)
    case text(String)
    case color(OKLCHColor)
    case list([SkinValue])
    case record([String: SkinValue])

    var type: SkinValueType {
        switch self {
        case .null: .null
        case .boolean: .boolean
        case .number: .number
        case .text: .text
        case .color: .color
        case .list: .list
        case .record: .record
        }
    }

    var numberValue: Double? {
        switch self {
        case .number(let value): return value.isFinite ? value : nil
        case .boolean(let value): return value ? 1 : 0
        case .text(let value): return Double(value)
        default: return nil
        }
    }

    func number(_ fallback: Double = 0) -> Double { numberValue ?? fallback }
    func integer(_ fallback: Int = 0) -> Int {
        guard let number = numberValue else { return fallback }
        return Int(min(1_000_000_000, max(-1_000_000_000, number)))
    }

    var isTruthy: Bool {
        switch self {
        case .null: return false
        case .boolean(let value): return value
        case .number(let value): return value != 0 && value.isFinite
        case .text(let value): return !value.isEmpty
        case .color: return true
        case .list(let value): return !value.isEmpty
        case .record(let value): return !value.isEmpty
        }
    }

    var textValue: String {
        switch self {
        case .null: return ""
        case .boolean(let value): return value ? "true" : "false"
        case .number(let value): return Self.format(value)
        case .text(let value): return value
        case .color(let value): return value.hexString
        case .list(let value): return value.map(\.textValue).joined(separator: ", ")
        case .record: return ""
        }
    }

    var colorValue: OKLCHColor? {
        switch self {
        case .color(let value): return value
        case .text(let value): return OKLCHColor(named: value)
        default: return nil
        }
    }

    var listValue: [SkinValue] {
        if case .list(let value) = self { return value }
        return []
    }

    /// Member access never fails: an absent field reads as null, like an empty optional.
    subscript(member member: String) -> SkinValue {
        switch self {
        case .record(let fields):
            return fields[member] ?? .null
        case .color(let color):
            switch member {
            case "srgb", "displayP3":
                let components = ColorRenderingAdapter.resolve(color, target: member == "displayP3" ? .displayP3 : .sRGB)
                return .record(["red": .number(components.red), "green": .number(components.green), "blue": .number(components.blue), "alpha": .number(components.alpha)])
            case "oklch": return .record(["l": .number(color.lightness), "c": .number(color.chroma), "h": .number((color.hue ?? 0) * 360), "a": .number(color.alpha)])
            case "l", "lightness": return .number(color.lightness)
            case "c", "chroma": return .number(color.chroma)
            case "h", "hue": return .number((color.hue ?? 0) * 360)
            case "a", "alpha": return .number(color.alpha)
            default: return .null
            }
        case .list(let items):
            switch member {
            case "count", "length": return .number(Double(items.count))
            case "first": return items.first ?? .null
            case "last": return items.last ?? .null
            default: return .null
            }
        case .text(let text):
            return member == "length" || member == "count" ? .number(Double(text.count)) : .null
        default:
            return .null
        }
    }

    subscript(index index: Int) -> SkinValue {
        switch self {
        case .list(let items):
            guard !items.isEmpty else { return .null }
            let resolved = index < 0 ? items.count + index : index
            return items.indices.contains(resolved) ? items[resolved] : .null
        case .text(let text):
            let characters = Array(text)
            let resolved = index < 0 ? characters.count + index : index
            return characters.indices.contains(resolved) ? .text(String(characters[resolved])) : .null
        default:
            return .null
        }
    }

    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%g", value)
    }

    init(_ parameter: SkinParameterValue) {
        switch parameter {
        case .null: self = .null
        case .boolean(let value): self = .boolean(value)
        case .number(let value): self = .number(value)
        case .text(let value): self = .text(value)
        case .array(let items): self = .list(items.map(SkinValue.init))
        case .object(let fields): self = .record(fields.mapValues(SkinValue.init))
        }
    }

    /// JSON form for persistence and for adapters that accept dictionaries.
    var parameterValue: SkinParameterValue {
        switch self {
        case .null: return .null
        case .boolean(let value): return .boolean(value)
        case .number(let value): return .number(value)
        case .text(let value): return .text(value)
        case .color(let value): return .text(value.hexString)
        case .list(let items): return .array(items.map(\.parameterValue))
        case .record(let fields): return .object(fields.mapValues(\.parameterValue))
        }
    }
}

enum SkinValueType: String, Equatable {
    case any, null, boolean, number, text, color, list, record

    /// Whether a value of `self` can be used where `expected` is required.
    func conforms(to expected: SkinValueType) -> Bool {
        if expected == .any || self == .any || self == expected { return true }
        switch (self, expected) {
        case (.boolean, .number), (.number, .boolean): return true
        case (.text, .color): return true
        case (_, .text): return self != .record
        case (.null, _): return true
        default: return false
        }
    }
}

extension OKLCHColor {
    static let clear = OKLCHColor(lightness: 0, chroma: 0, hue: nil, alpha: 0)
    static let black = OKLCHColor(lightness: 0, chroma: 0, hue: nil, alpha: 1)
    static let white = OKLCHColor(lightness: 1, chroma: 0, hue: nil, alpha: 1)

    init(_ color: NSColor) {
        self = ColorRenderingAdapter.makeOKLCHColor(from: color) ?? .black
    }

    /// Hex (`#RGB`, `#RRGGBB`, `#RRGGBBAA`, sRGB) or one of a few plain names.
    init?(named value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "clear", "transparent": self = .clear; return
        case "black": self = .black; return
        case "white": self = .white; return
        default: break
        }
        guard trimmed.hasPrefix("#") else { return nil }
        var hex = String(trimmed.dropFirst())
        if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let raw = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let red = Double((raw >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((raw >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((raw >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(raw & 0xFF) / 255 : 1
        self.init(NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
    }

    /// Components in 0...1, interpreted in sRGB.
    static func rgb(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> OKLCHColor {
        OKLCHColor(NSColor(srgbRed: red.clamped01, green: green.clamped01, blue: blue.clamped01, alpha: alpha.clamped01))
    }

    /// Author-facing hue is in degrees, as in CSS `oklch()`.
    static func oklch(_ lightness: Double, _ chroma: Double, _ hueDegrees: Double, _ alpha: Double = 1) -> OKLCHColor {
        OKLCHColor(lightness: lightness.clamped01, chroma: max(0, chroma), hue: hueDegrees / 360, alpha: alpha.clamped01)
    }

    var swiftUIColor: Color { ColorRenderingAdapter.makeSwiftUIColor(self) }
    var nsColor: NSColor { ColorRenderingAdapter.makeNSColor(self) }
    var cgColor: CGColor { ColorRenderingAdapter.makeCGColor(self) }

    var hexString: String {
        let resolved = ColorRenderingAdapter.resolve(self, target: .sRGB)
        let components = [resolved.red, resolved.green, resolved.blue, resolved.alpha]
            .map { String(format: "%02X", Int(($0.clamped01 * 255).rounded())) }
        return "#" + components.joined()
    }

    /// Lyrics and other adapters read Display P3 first, with an sRGB fallback.
    var adapterDictionary: [String: String] {
        ["displayP3": ColorRenderingAdapter.makeCSSColor(self, target: .displayP3),
         "srgb": ColorRenderingAdapter.makeCSSSRGBFallback(self)]
    }

    func withAlpha(_ value: Double) -> OKLCHColor {
        var copy = self
        copy.alpha = value.clamped01
        return copy
    }

    /// Mixed in OKLab, so mid points keep their perceived lightness.
    func mixed(with other: OKLCHColor, amount: Double) -> OKLCHColor {
        let t = amount.clamped01
        let lhs = OKColor.okLCHToOKLab(.init(l: CGFloat(lightness), c: CGFloat(hue == nil ? 0 : chroma), h: CGFloat(hue ?? 0)))
        let rhs = OKColor.okLCHToOKLab(.init(l: CGFloat(other.lightness), c: CGFloat(other.hue == nil ? 0 : other.chroma), h: CGFloat(other.hue ?? 0)))
        let lab = OKColor.OKLab(
            l: lhs.l + (rhs.l - lhs.l) * CGFloat(t),
            a: lhs.a + (rhs.a - lhs.a) * CGFloat(t),
            b: lhs.b + (rhs.b - lhs.b) * CGFloat(t)
        )
        let lch = OKColor.okLabToOKLCH(lab)
        let chroma = Double(lch.c)
        return OKLCHColor(
            lightness: Double(lch.l), chroma: chroma,
            hue: chroma > ColorRenderingAdapter.achromaticChromaEpsilon ? Double(lch.h) : (hue ?? other.hue),
            alpha: alpha + (other.alpha - alpha) * t
        )
    }

    func adjusting(lightness delta: Double = 0, chromaScale: Double = 1, hueDegrees: Double = 0) -> OKLCHColor {
        OKLCHColor(
            lightness: (lightness + delta).clamped01,
            chroma: max(0, chroma * chromaScale),
            hue: hue.map { $0 + hueDegrees / 360 },
            alpha: alpha
        )
    }

    /// A legible near-black or near-white for text placed on this colour.
    var contrastingForeground: OKLCHColor {
        lightness > 0.62 ? OKLCHColor(lightness: 0.16, chroma: 0, hue: nil) : OKLCHColor(lightness: 0.97, chroma: 0, hue: nil)
    }
}

extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
