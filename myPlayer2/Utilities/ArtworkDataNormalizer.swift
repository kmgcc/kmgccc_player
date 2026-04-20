//
//  ArtworkDataNormalizer.swift
//  myPlayer2
//
//  Shared ImageIO-based artwork normalization for import and persistence.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ArtworkDataNormalizer {
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
}
