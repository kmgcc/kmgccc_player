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
    static let importMaxPixelSize = 1_200
    static let storedMaxPixelSize = 1_200

    static func normalizedJPEGData(
        from data: Data,
        maxPixelSize: Int = storedMaxPixelSize,
        compressionQuality: CGFloat = 0.86
    ) -> Data? {
        guard !data.isEmpty else { return nil }

        return autoreleasepool {
            guard
                let source = CGImageSourceCreateWithData(
                    data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                )
            else {
                return nil
            }

            return normalizedJPEGData(
                from: source,
                maxPixelSize: maxPixelSize,
                compressionQuality: compressionQuality
            )
        }
    }

    static func normalizedJPEGData(
        from fileURL: URL,
        maxPixelSize: Int = storedMaxPixelSize,
        compressionQuality: CGFloat = 0.86
    ) -> Data? {
        autoreleasepool {
            guard
                let source = CGImageSourceCreateWithURL(
                    fileURL as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                )
            else {
                return nil
            }

            return normalizedJPEGData(
                from: source,
                maxPixelSize: maxPixelSize,
                compressionQuality: compressionQuality
            )
        }
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

    private static func normalizedJPEGData(
        from source: CGImageSource,
        maxPixelSize: Int,
        compressionQuality: CGFloat
    ) -> Data? {
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: min(max(compressionQuality, 0), 1)
        ]
        CGImageDestinationAddImage(destination, cgImage, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
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
