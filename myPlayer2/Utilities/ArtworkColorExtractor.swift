//
//  ArtworkColorExtractor.swift
//  myPlayer2
//
//  TrueMusic - Artwork Color Extraction
//  Computes a softened accent color from album artwork.
//

import AppKit
import CoreImage

enum ArtworkColorExtractor {

    private static let ciContext = CIContext(options: [
        .workingColorSpace: NSNull(),
    ])

    static func averageColor(from data: Data) -> NSColor? {
        guard let image = NSImage(data: data),
            let tiff = image.tiffRepresentation,
            let ciImage = CIImage(data: tiff)
        else { return nil }

        let extent = ciImage.extent
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)

        guard let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        return NSColor(
            calibratedRed: CGFloat(pixel[0]) / 255.0,
            green: CGFloat(pixel[1]) / 255.0,
            blue: CGFloat(pixel[2]) / 255.0,
            alpha: 1.0
        )
    }

    static func adjustedAccent(from color: NSColor, isDarkMode: Bool) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // Keep color soft and readable (avoid heavy saturation).
        saturation = min(max(saturation, 0.08), 0.22)

        if isDarkMode {
            // Near-white in dark mode.
            brightness = min(max(brightness, 0.98), 1.0)
        } else {
            // Near-black in light mode.
            brightness = min(max(brightness, 0.08), 0.15)
        }

        return NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1.0)
    }

    static func cssRGBA(_ color: NSColor, alpha: CGFloat) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return "rgba(255,255,255,\(alpha))"
        }

        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return "rgba(\(r),\(g),\(b),\(alpha))"
    }
}
