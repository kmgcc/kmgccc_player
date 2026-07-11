//
//  ArtworkRenderingFallback.swift
//  myPlayer2
//
//  Deterministic, in-memory artwork fallback used by rendering/color pipelines.
//  This path deliberately has no dependency on encrypted or first-party art.
//

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ArtworkRenderingFallback {
    nonisolated static let identity = "rendering-fallback:programmatic-v1"
    nonisolated static let defaultTrackID = UUID(uuidString: "7E9E8E9D-1B19-4D9B-B89C-1041F87D55E8")!

    enum ImageKind: String, Sendable {
        case artwork
        case background
        case shape
        case mask
        case frame
        case circleOuter
        case circleInner
    }

    private nonisolated static let artworkPixelSize = 1_024
    private nonisolated(unsafe) static let dataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 32
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    nonisolated static var data: Data? {
        data(for: nil)
    }

    nonisolated static var checksum: UInt64 {
        checksum(for: nil)
    }

    nonisolated static func data(for preferredTrackID: UUID?) -> Data? {
        let trackID = resolvedTrackID(preferredTrackID)
        let key = "artwork-v1-\(trackID.uuidString)" as NSString
        if let cached = dataCache.object(forKey: key) {
            return cached as Data
        }

        guard let image = image(
            kind: .artwork,
            seed: stableIndexSeed(for: trackID),
            pixelSize: CGSize(width: artworkPixelSize, height: artworkPixelSize),
            isDark: false,
            themeColor: nil
        ), let encoded = pngData(for: image) else {
            return nil
        }

        dataCache.setObject(encoded as NSData, forKey: key, cost: encoded.count)
        return encoded
    }

    nonisolated static func checksum(for preferredTrackID: UUID?) -> UInt64 {
        ArtworkAssetStore.checksum(for: data(for: preferredTrackID))
    }

    nonisolated static func identity(for preferredTrackID: UUID?) -> String {
        let seed = stableIndexSeed(for: resolvedTrackID(preferredTrackID))
        return "\(identity):\(String(format: "%016llX", seed))"
    }

    nonisolated static func shouldUse(for artworkData: Data?, isArtworkLoading: Bool) -> Bool {
        artworkData?.isEmpty != false && !isArtworkLoading
    }

    nonisolated static func resolvedTrackID(_ preferredTrackID: UUID?) -> UUID {
        preferredTrackID ?? defaultTrackID
    }

    /// Generates a stable bitmap at an exact pixel size. Callers should pass
    /// logicalSize * backingScaleFactor when they need a Retina asset.
    nonisolated static func image(
        kind: ImageKind,
        seed: UInt64,
        pixelSize: CGSize,
        isDark: Bool,
        themeColor: NSColor?
    ) -> CGImage? {
        let width = max(1, Int(pixelSize.width.rounded(.up)))
        let height = max(1, Int(pixelSize.height.rounded(.up)))
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high

        let accent = resolvedAccent(seed: seed, isDark: isDark, themeColor: themeColor)
        let background = isDark
            ? RGB(red: 0.055, green: 0.065, blue: 0.090)
            : RGB(red: 0.900, green: 0.915, blue: 0.940)
        let backgroundEnd = isDark
            ? RGB(red: 0.125, green: 0.145, blue: 0.190)
            : RGB(red: 0.735, green: 0.775, blue: 0.835)

        switch kind {
        case .background:
            drawGradient(
                in: context,
                bounds: bounds,
                colors: [Self.cgColor(background), Self.cgColor(blend(background, accent, amount: 0.22)), Self.cgColor(backgroundEnd)],
                locations: [0, 0.58, 1]
            )
            drawSoftOrb(in: context, bounds: bounds, center: CGPoint(x: 0.72, y: 0.28), radius: 0.34, color: Self.cgColor(accent), opacity: isDark ? 0.16 : 0.10)

        case .artwork:
            drawGradient(
                in: context,
                bounds: bounds,
                colors: [Self.cgColor(backgroundEnd), Self.cgColor(accent), Self.cgColor(background)],
                locations: [0, 0.52, 1]
            )
            let inset = min(CGFloat(width), CGFloat(height)) * 0.075
            let card = bounds.insetBy(dx: inset, dy: inset)
            context.saveGState()
            context.addPath(CGPath(roundedRect: card, cornerWidth: inset * 0.72, cornerHeight: inset * 0.72, transform: nil))
            context.clip()
            drawSoftOrb(in: context, bounds: card, center: CGPoint(x: 0.25, y: 0.30), radius: 0.38, color: CGColor(gray: 1, alpha: 1), opacity: isDark ? 0.12 : 0.22)
            drawSoftOrb(in: context, bounds: card, center: CGPoint(x: 0.78, y: 0.72), radius: 0.42, color: Self.cgColor(background), opacity: 0.20)
            context.restoreGState()

        case .shape:
            let variant = Int(seed % 3)
            let margin = min(CGFloat(width), CGFloat(height)) * (0.12 + CGFloat(variant) * 0.025)
            let shapeRect = bounds.insetBy(dx: margin, dy: margin)
            context.saveGState()
            switch variant {
            case 0:
                context.addPath(CGPath(roundedRect: shapeRect, cornerWidth: shapeRect.width * 0.28, cornerHeight: shapeRect.height * 0.28, transform: nil))
            case 1:
                context.addEllipse(in: shapeRect)
            default:
                let path = CGMutablePath()
                path.move(to: CGPoint(x: shapeRect.midX, y: shapeRect.minY))
                path.addCurve(
                    to: CGPoint(x: shapeRect.maxX, y: shapeRect.midY),
                    control1: CGPoint(x: shapeRect.maxX * 0.90, y: shapeRect.minY),
                    control2: CGPoint(x: shapeRect.maxX, y: shapeRect.minY * 1.25)
                )
                path.addCurve(
                    to: CGPoint(x: shapeRect.midX, y: shapeRect.maxY),
                    control1: CGPoint(x: shapeRect.maxX, y: shapeRect.maxY * 0.90),
                    control2: CGPoint(x: shapeRect.maxX * 0.85, y: shapeRect.maxY)
                )
                path.addCurve(
                    to: CGPoint(x: shapeRect.minX, y: shapeRect.midY),
                    control1: CGPoint(x: shapeRect.minX * 1.20, y: shapeRect.maxY),
                    control2: CGPoint(x: shapeRect.minX, y: shapeRect.maxY * 0.78)
                )
                path.closeSubpath()
                context.addPath(path)
            }
            context.clip()
            drawGradient(
                in: context,
                bounds: bounds,
                colors: [Self.cgColor(accent), Self.cgColor(blend(accent, RGB(red: 1, green: 1, blue: 1), amount: isDark ? 0.14 : 0.30))],
                locations: [0, 1]
            )
            context.restoreGState()

        case .mask:
            let inset = min(CGFloat(width), CGFloat(height)) * 0.13
            let rect = bounds.insetBy(dx: inset, dy: inset)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width * 0.22, cornerHeight: rect.height * 0.22, transform: nil))
            context.fillPath()

        case .frame:
            let inset = min(CGFloat(width), CGFloat(height)) * 0.10
            let rect = bounds.insetBy(dx: inset, dy: inset)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.92))
            context.setLineWidth(max(2, min(CGFloat(width), CGFloat(height)) * 0.045))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width * 0.18, cornerHeight: rect.height * 0.18, transform: nil))
            context.strokePath()

        case .circleOuter, .circleInner:
            let inset = kind == .circleOuter ? 0.08 : 0.22
            let circleRect = bounds.insetBy(dx: min(CGFloat(width), CGFloat(height)) * inset, dy: min(CGFloat(width), CGFloat(height)) * inset)
            context.setFillColor(CGColor(gray: 1, alpha: 0.96))
            context.fillEllipse(in: circleRect)
            if kind == .circleOuter {
                context.setBlendMode(.clear)
                let hole = circleRect.insetBy(dx: circleRect.width * 0.22, dy: circleRect.height * 0.22)
                context.fillEllipse(in: hole)
            }
        }

        return context.makeImage()
    }

    private struct RGB {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
    }

    private nonisolated static func cgColor(_ value: RGB) -> CGColor {
        CGColor(red: value.red, green: value.green, blue: value.blue, alpha: 1)
    }

    private nonisolated static func pngData(for image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGInterlaceType: 0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private nonisolated static func drawGradient(
        in context: CGContext,
        bounds: CGRect,
        colors: [CGColor],
        locations: [CGFloat]
    ) {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) else { return }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: bounds.minX, y: bounds.maxY),
            end: CGPoint(x: bounds.maxX, y: bounds.minY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    private nonisolated static func drawSoftOrb(
        in context: CGContext,
        bounds: CGRect,
        center: CGPoint,
        radius: CGFloat,
        color: CGColor,
        opacity: CGFloat
    ) {
        let centerPoint = CGPoint(x: bounds.minX + bounds.width * center.x, y: bounds.minY + bounds.height * center.y)
        let radius = max(1, min(bounds.width, bounds.height) * radius)
        context.saveGState()
        context.setFillColor(color.copy(alpha: opacity) ?? color)
        context.fillEllipse(in: CGRect(x: centerPoint.x - radius, y: centerPoint.y - radius, width: radius * 2, height: radius * 2))
        context.restoreGState()
    }

    private nonisolated static func resolvedAccent(seed: UInt64, isDark: Bool, themeColor: NSColor?) -> RGB {
        if let themeColor, let rgb = themeColor.usingColorSpace(.sRGB) {
            let base = RGB(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
            return blend(base, isDark ? RGB(red: 0.22, green: 0.25, blue: 0.32) : RGB(red: 0.72, green: 0.77, blue: 0.86), amount: isDark ? 0.42 : 0.28)
        }

        let variation = CGFloat(seed % 11) / 100
        return isDark
            ? RGB(red: 0.24 + variation, green: 0.30 + variation * 0.7, blue: 0.43 + variation)
            : RGB(red: 0.48 + variation, green: 0.58 + variation * 0.7, blue: 0.74 + variation)
    }

    private nonisolated static func blend(_ lhs: RGB, _ rhs: RGB, amount: CGFloat) -> RGB {
        let t = min(max(amount, 0), 1)
        return RGB(
            red: lhs.red + (rhs.red - lhs.red) * t,
            green: lhs.green + (rhs.green - lhs.green) * t,
            blue: lhs.blue + (rhs.blue - lhs.blue) * t
        )
    }

    private nonisolated static func stableIndexSeed(for trackID: UUID) -> UInt64 {
        withUnsafeBytes(of: trackID.uuid) { bytes in
            bytes.reduce(UInt64(0xcbf29ce484222325)) { hash, byte in
                (hash ^ UInt64(byte)) &* UInt64(0x100000001b3)
            }
        }
    }
}
