//
//  ArtworkDataNormalizer.swift
//  myPlayer2
//
//  Shared ImageIO-based artwork normalization for import and persistence.
//

import AppKit
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ArtworkDataNormalizer {
    // Legacy call-site budgets, retained until import callers migrate. Source
    // artwork is never resized or re-encoded; only derivatives have budgets.
    static let importMaxPixelSize = 2_560
    static let storedMaxPixelSize = 2_560
    /// Imported files below this resolution are treated as an unusable local
    /// cover; import asks providers for a replacement instead of keeping it.
    static let preferredArtworkPixelSize = 800

    static func normalizedJPEGData(
        from data: Data,
        maxPixelSize: Int = storedMaxPixelSize,
        compressionQuality: CGFloat = 0.86
    ) -> Data? {
        // Compatibility entry point: maxPixelSize and compressionQuality no
        // longer apply to authoritative artwork, regardless of input format.
        originalData(from: data)
    }

    static func normalizedJPEGData(
        from fileURL: URL,
        maxPixelSize: Int = storedMaxPixelSize,
        compressionQuality: CGFloat = 0.86
    ) -> Data? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return originalData(from: data)
    }

    /// Authoritative artwork always retains the downloaded/imported bytes.
    static func originalData(from data: Data) -> Data? {
        guard fileExtension(for: data) != nil else { return nil }
        return data
    }

    static func fileExtension(for data: Data) -> String? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, width.intValue > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber, height.intValue > 0,
              let type = CGImageSourceGetType(source),
              let ext = UTType(type as String)?.preferredFilenameExtension else { return nil }
        return ext == "jpeg" ? "jpg" : ext
    }

    static func isDecodableImage(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return autoreleasepool {
            CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ) != nil
        }
    }

    /// Longest edge of the encoded image, read from the header without decoding it.
    static func maxPixelSize(of data: Data) -> Int? {
        pixelDimensions(of: data).map { max($0.width, $0.height) }
    }

    /// The square area available without upscaling or distorting the cover.
    static func minPixelSize(of data: Data) -> Int? {
        pixelDimensions(of: data).map { min($0.width, $0.height) }
    }

    private static func pixelDimensions(of data: Data) -> (width: Int, height: Int)? {
        guard !data.isEmpty else { return nil }
        return autoreleasepool {
            guard
                let source = CGImageSourceCreateWithData(
                    data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                ),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
            else { return nil }
            return (width.intValue, height.intValue)
        }
    }

    /// True when the image is decodable and its shorter edge is below the
    /// preferred import resolution.
    static func isBelowPreferredResolution(_ data: Data) -> Bool {
        guard let pixelSize = minPixelSize(of: data) else { return false }
        return pixelSize < preferredArtworkPixelSize
    }

    /// Whether a provider cover should replace the current one. A missing
    /// current cover always qualifies; otherwise the candidate must carry more
    /// pixels so a low-resolution online result cannot downgrade a local cover.
    static func isHigherResolution(_ candidate: Data, than current: Data?) -> Bool {
        guard let candidatePixelSize = minPixelSize(of: candidate) else { return false }
        guard let current, let currentPixelSize = minPixelSize(of: current) else {
            return true
        }
        return candidatePixelSize > currentPixelSize
    }

    /// Compresses artwork derivatives: 85% quality JPEG for opaque artwork, PNG for images with alpha.
    static func encodedDerivativeData(
        for image: NSImage,
        lossyCompressionQuality: CGFloat = 0.85
    ) -> Data? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff)
            else {
                return nil
            }
            return rep.representation(using: .jpeg, properties: [.compressionFactor: lossyCompressionQuality])
                ?? rep.representation(using: .png, properties: [:])
        }

        let alphaInfo = cgImage.alphaInfo
        let hasAlpha = alphaInfo == .first
            || alphaInfo == .last
            || alphaInfo == .premultipliedFirst
            || alphaInfo == .premultipliedLast
            || alphaInfo == .alphaOnly

        let uti = hasAlpha ? UTType.png.identifier : UTType.jpeg.identifier
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, uti as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = hasAlpha ? [:] : [
            kCGImageDestinationLossyCompressionQuality: min(max(lossyCompressionQuality, 0), 1)
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }
}
