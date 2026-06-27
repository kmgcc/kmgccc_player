//
//  ColorRenderingAdapter.swift
//  myPlayer2
//
//  Central output boundary for perceptual colour decisions.
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

nonisolated struct OKLCHColor: Equatable, Sendable {
    var lightness: Double
    var chroma: Double
    var hue: Double?
    var alpha: Double

    init(lightness: Double, chroma: Double, hue: Double?, alpha: Double = 1) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
        self.alpha = alpha
    }

    init(_ color: OKColor.OKLCH, alpha: Double = 1) {
        self.lightness = Double(color.l)
        self.chroma = Double(color.c)
        self.hue = Double(color.h)
        self.alpha = alpha
    }
}

nonisolated enum ColorRenderTarget: String, Equatable, Sendable {
    case displayP3
    case sRGB
    case linearDisplayP3
}

nonisolated struct ResolvedRGBColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
    var target: ColorRenderTarget
    var isLinear: Bool
    var requestedChroma: Double
    var resolvedChroma: Double

    var wasGamutMapped: Bool {
        resolvedChroma + ColorRenderingAdapter.gamutMappingTolerance < requestedChroma
    }
}

nonisolated enum ColorRenderingAdapter {
    static let achromaticChromaEpsilon = 0.0005
    static let gamutMappingTolerance = 0.000001

    static func resolve(
        _ color: OKLCHColor,
        target: ColorRenderTarget
    ) -> ResolvedRGBColor {
        let mapped = mappedOKLCH(color, target: target)
        let lab = OKColor.okLCHToOKLab(
            OKColor.OKLCH(
                l: CGFloat(mapped.lightness),
                c: CGFloat(mapped.chroma),
                h: CGFloat(mapped.hue)
            )
        )
        let linearSRGB = OKColor.okLabToLinearSRGB(lab)
        let alpha = clamp01(color.alpha)

        switch target {
        case .sRGB:
            return ResolvedRGBColor(
                red: clamp01(Double(OKColor.linearToSRGB(linearSRGB.r))),
                green: clamp01(Double(OKColor.linearToSRGB(linearSRGB.g))),
                blue: clamp01(Double(OKColor.linearToSRGB(linearSRGB.b))),
                alpha: alpha,
                target: target,
                isLinear: false,
                requestedChroma: mapped.requestedChroma,
                resolvedChroma: mapped.chroma
            )
        case .displayP3:
            let p3 = linearSRGBToLinearDisplayP3(linearSRGB)
            return ResolvedRGBColor(
                red: clamp01(Double(OKColor.linearToSRGB(p3.r))),
                green: clamp01(Double(OKColor.linearToSRGB(p3.g))),
                blue: clamp01(Double(OKColor.linearToSRGB(p3.b))),
                alpha: alpha,
                target: target,
                isLinear: false,
                requestedChroma: mapped.requestedChroma,
                resolvedChroma: mapped.chroma
            )
        case .linearDisplayP3:
            let p3 = linearSRGBToLinearDisplayP3(linearSRGB)
            return ResolvedRGBColor(
                red: clamp01(Double(p3.r)),
                green: clamp01(Double(p3.g)),
                blue: clamp01(Double(p3.b)),
                alpha: alpha,
                target: target,
                isLinear: true,
                requestedChroma: mapped.requestedChroma,
                resolvedChroma: mapped.chroma
            )
        }
    }

    static func resolve(
        _ color: NSColor,
        target: ColorRenderTarget
    ) -> ResolvedRGBColor? {
        guard let oklch = makeOKLCHColor(from: color) else { return nil }
        return resolve(oklch, target: target)
    }

    static func makeSwiftUIColor(
        _ color: OKLCHColor,
        target: ColorRenderTarget = .displayP3
    ) -> Color {
        let uiTarget = target == .linearDisplayP3 ? ColorRenderTarget.displayP3 : target
        let resolved = resolve(color, target: uiTarget)
        switch uiTarget {
        case .displayP3:
            return Color(
                .displayP3,
                red: resolved.red,
                green: resolved.green,
                blue: resolved.blue,
                opacity: resolved.alpha
            )
        case .sRGB:
            return Color(
                .sRGB,
                red: resolved.red,
                green: resolved.green,
                blue: resolved.blue,
                opacity: resolved.alpha
            )
        case .linearDisplayP3:
            return Color(
                .displayP3,
                red: resolved.red,
                green: resolved.green,
                blue: resolved.blue,
                opacity: resolved.alpha
            )
        }
    }

    static func makeSwiftUIColor(
        _ color: NSColor,
        target: ColorRenderTarget = .displayP3
    ) -> Color {
        guard let oklch = makeOKLCHColor(from: color) else {
            return Color(nsColor: color)
        }
        return makeSwiftUIColor(oklch, target: target)
    }

    static func makeNSColor(
        _ color: OKLCHColor,
        target: ColorRenderTarget = .displayP3
    ) -> NSColor {
        let uiTarget = target == .linearDisplayP3 ? ColorRenderTarget.displayP3 : target
        let resolved = resolve(color, target: uiTarget)
        switch uiTarget {
        case .displayP3:
            return NSColor(
                displayP3Red: CGFloat(resolved.red),
                green: CGFloat(resolved.green),
                blue: CGFloat(resolved.blue),
                alpha: CGFloat(resolved.alpha)
            )
        case .sRGB:
            return NSColor(
                srgbRed: CGFloat(resolved.red),
                green: CGFloat(resolved.green),
                blue: CGFloat(resolved.blue),
                alpha: CGFloat(resolved.alpha)
            )
        case .linearDisplayP3:
            return NSColor(
                displayP3Red: CGFloat(resolved.red),
                green: CGFloat(resolved.green),
                blue: CGFloat(resolved.blue),
                alpha: CGFloat(resolved.alpha)
            )
        }
    }

    static func makeNSColor(
        _ color: NSColor,
        target: ColorRenderTarget = .displayP3
    ) -> NSColor {
        guard let oklch = makeOKLCHColor(from: color) else { return color }
        return makeNSColor(oklch, target: target)
    }

    static func makeCGColor(
        _ color: OKLCHColor,
        target: ColorRenderTarget = .displayP3
    ) -> CGColor {
        let resolved = resolve(color, target: target)
        let colorSpace: CGColorSpace
        switch target {
        case .displayP3:
            colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        case .sRGB:
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        case .linearDisplayP3:
            colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? CGColorSpaceCreateDeviceRGB()
        }
        return CGColor(
            colorSpace: colorSpace,
            components: [
                CGFloat(resolved.red),
                CGFloat(resolved.green),
                CGFloat(resolved.blue),
                CGFloat(resolved.alpha)
            ]
        ) ?? makeNSColor(color, target: target).cgColor
    }

    static func makeCGColor(
        _ color: NSColor,
        target: ColorRenderTarget = .displayP3
    ) -> CGColor {
        guard let oklch = makeOKLCHColor(from: color) else {
            return color.cgColor
        }
        return makeCGColor(oklch, target: target)
    }

    static func makeMetalColor(_ color: OKLCHColor) -> SIMD4<Float> {
        let resolved = resolve(color, target: .linearDisplayP3)
        return SIMD4<Float>(
            Float(resolved.red),
            Float(resolved.green),
            Float(resolved.blue),
            Float(resolved.alpha)
        )
    }

    static func makeMetalColor(_ color: NSColor) -> SIMD4<Float>? {
        guard let oklch = makeOKLCHColor(from: color) else { return nil }
        return makeMetalColor(oklch)
    }

    static func makeCSSColor(
        _ color: OKLCHColor,
        target: ColorRenderTarget = .displayP3
    ) -> String {
        switch target {
        case .displayP3:
            let resolved = resolve(color, target: .displayP3)
            return "color(display-p3 \(cssNumber(resolved.red)) \(cssNumber(resolved.green)) \(cssNumber(resolved.blue)) / \(cssNumber(resolved.alpha)))"
        case .sRGB:
            return makeCSSSRGBFallback(color)
        case .linearDisplayP3:
            let resolved = resolve(color, target: .displayP3)
            return "color(display-p3 \(cssNumber(resolved.red)) \(cssNumber(resolved.green)) \(cssNumber(resolved.blue)) / \(cssNumber(resolved.alpha)))"
        }
    }

    static func makeCSSColor(
        _ color: NSColor,
        target: ColorRenderTarget = .displayP3
    ) -> String? {
        guard let oklch = makeOKLCHColor(from: color) else { return nil }
        return makeCSSColor(oklch, target: target)
    }

    static func makeCSSSRGBFallback(_ color: OKLCHColor) -> String {
        let resolved = resolve(color, target: .sRGB)
        let r = Int((resolved.red * 255).rounded())
        let g = Int((resolved.green * 255).rounded())
        let b = Int((resolved.blue * 255).rounded())
        if resolved.alpha >= 1 {
            return "rgb(\(r) \(g) \(b))"
        }
        return "rgb(\(r) \(g) \(b) / \(cssNumber(resolved.alpha)))"
    }

    static func makeCSSSRGBFallback(_ color: NSColor) -> String? {
        guard let oklch = makeOKLCHColor(from: color) else { return nil }
        return makeCSSSRGBFallback(oklch)
    }

    static func makeCSSColorDeclaration(
        property: String,
        color: OKLCHColor
    ) -> String {
        let fallback = makeCSSSRGBFallback(color)
        let p3 = makeCSSColor(color, target: .displayP3)
        return """
        \(property): \(fallback);
        @supports (color: color(display-p3 1 0 0)) {
          \(property): \(p3);
        }
        """
    }

    static func makeCSSColorDeclaration(
        property: String,
        color: NSColor
    ) -> String? {
        guard let oklch = makeOKLCHColor(from: color) else { return nil }
        return makeCSSColorDeclaration(property: property, color: oklch)
    }

    @MainActor
    static func configureNativeWindowForDisplayP3(_ window: NSWindow) {
        window.colorSpace = .displayP3
    }

    static func makeOKLCHColor(
        from color: NSColor,
        alpha overrideAlpha: Double? = nil
    ) -> OKLCHColor? {
        guard let lch = OKColor.nsColorToOKLCH(color) else { return nil }
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let alpha = overrideAlpha ?? Double(rgb.alphaComponent)
        let chroma = Double(lch.c)
        return OKLCHColor(
            lightness: Double(lch.l),
            chroma: chroma,
            hue: chroma > achromaticChromaEpsilon ? Double(lch.h) : nil,
            alpha: alpha
        )
    }

    private static func mappedOKLCH(
        _ color: OKLCHColor,
        target: ColorRenderTarget
    ) -> (lightness: Double, chroma: Double, hue: Double, requestedChroma: Double) {
        let lightness = clamp01(color.lightness)
        let requestedChroma = max(0, color.chroma)
        guard let hue = color.hue,
              requestedChroma > achromaticChromaEpsilon else {
            return (lightness, 0, 0, 0)
        }

        let normalizedHue = normalizeHue(hue)
        guard !isInTargetGamut(lightness: lightness, chroma: requestedChroma, hue: normalizedHue, target: target) else {
            return (lightness, requestedChroma, normalizedHue, requestedChroma)
        }

        var lo = 0.0
        var hi = requestedChroma
        for _ in 0..<22 {
            let mid = (lo + hi) * 0.5
            if isInTargetGamut(lightness: lightness, chroma: mid, hue: normalizedHue, target: target) {
                lo = mid
            } else {
                hi = mid
            }
        }
        return (lightness, lo, normalizedHue, requestedChroma)
    }

    private static func isInTargetGamut(
        lightness: Double,
        chroma: Double,
        hue: Double,
        target: ColorRenderTarget
    ) -> Bool {
        let lab = OKColor.okLCHToOKLab(
            OKColor.OKLCH(l: CGFloat(lightness), c: CGFloat(chroma), h: CGFloat(hue))
        )
        let linearSRGB = OKColor.okLabToLinearSRGB(lab)
        switch target {
        case .sRGB:
            return isUnitRGB(linearSRGB)
        case .displayP3, .linearDisplayP3:
            return isUnitRGB(linearSRGBToLinearDisplayP3(linearSRGB))
        }
    }

    private static func linearSRGBToLinearDisplayP3(
        _ rgb: (r: CGFloat, g: CGFloat, b: CGFloat)
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let x = 0.4124564 * rgb.r + 0.3575761 * rgb.g + 0.1804375 * rgb.b
        let y = 0.2126729 * rgb.r + 0.7151522 * rgb.g + 0.0721750 * rgb.b
        let z = 0.0193339 * rgb.r + 0.1191920 * rgb.g + 0.9503041 * rgb.b
        return (
            r:  2.4934969 * x - 0.9313836 * y - 0.4027108 * z,
            g: -0.8294890 * x + 1.7626640 * y + 0.0236247 * z,
            b:  0.0358458 * x - 0.0761724 * y + 0.9568845 * z
        )
    }

    private static func isUnitRGB(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Bool {
        let epsilon: CGFloat = 0.0000001
        return rgb.r >= -epsilon && rgb.r <= 1 + epsilon
            && rgb.g >= -epsilon && rgb.g <= 1 + epsilon
            && rgb.b >= -epsilon && rgb.b <= 1 + epsilon
    }

    private static func normalizeHue(_ hue: Double) -> Double {
        let wrapped = hue.truncatingRemainder(dividingBy: 1)
        return wrapped < 0 ? wrapped + 1 : wrapped
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func cssNumber(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), clamp01(value))
    }
}
