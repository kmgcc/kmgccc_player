//
//  ArtAssetLoader.swift
//  myPlayer2
//
//  Loads art assets from .kmgasset files. When a local art runtime is present
//  the assets are decoded through it; otherwise callers fall back to the
//  in-repo programmatic artwork. A missing asset is a normal state.
//

import AppKit
import Foundation
import ImageIO
import SwiftUI

final class ArtAssetLoader: @unchecked Sendable {
    nonisolated static let shared = ArtAssetLoader()

    enum LoadError: Error, CustomStringConvertible {
        case missingFile(String)
        case badMagic(String)
        case unsupportedVersion(UInt8)
        case unsupportedAlgorithm(UInt8)
        case malformedHeader(String)
        case authenticationFailed(String)
        case runtimeUnavailable(String)
        case imageDecodeFailed(String)

        var description: String {
            switch self {
            case .missingFile(let logicalName):
                return "art asset is unavailable: \(logicalName)"
            case .badMagic(let logicalName):
                return "art asset is invalid: \(logicalName)"
            case .unsupportedVersion(let version):
                return "art asset version is unsupported: \(version)"
            case .unsupportedAlgorithm(let algorithm):
                return "art asset algorithm is unsupported: \(algorithm)"
            case .malformedHeader(let logicalName):
                return "art asset header is malformed: \(logicalName)"
            case .authenticationFailed(let logicalName):
                return "art asset could not be authenticated: \(logicalName)"
            case .runtimeUnavailable(let reason):
                return "art runtime is unavailable: \(reason)"
            case .imageDecodeFailed(let logicalName):
                return "art asset image could not be decoded: \(logicalName)"
            }
        }

        var isMissing: Bool {
            if case .missingFile = self { return true }
            return false
        }
    }

    private final class CGImageBox: NSObject {
        nonisolated let image: CGImage

        nonisolated init(_ image: CGImage) {
            self.image = image
        }
    }

    private nonisolated(unsafe) let imageCache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.countLimit = 96
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()

    private nonisolated init() {}

    nonisolated func cgImage(
        logicalName: String,
        in bundle: Bundle?,
        maxPixel: Int,
        fallbackToProgrammaticArt: Bool = false
    ) -> CGImage? {
        guard maxPixel > 0 else { return nil }
        let cacheKey = "\(logicalName)|px:\(maxPixel)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached.image
        }
        let fallbackCacheKey = "\(cacheKey)|programmatic" as NSString
        if fallbackToProgrammaticArt, let cached = imageCache.object(forKey: fallbackCacheKey) {
            return cached.image
        }

        do {
            let image = try loadCGImage(logicalName: logicalName, in: bundle, maxPixel: maxPixel)
            imageCache.setObject(CGImageBox(image), forKey: cacheKey, cost: byteCost(for: image))
            return image
        } catch {
            let isMissing = (error as? LoadError)?.isMissing ?? false
            if fallbackToProgrammaticArt {
                if !isMissing {
                    Log.warning(
                        "[ArtAssets] Resource could not be decoded; using built-in artwork: \(logicalName)",
                        category: .theme
                    )
                }
                guard let fallback = ArtworkRenderingFallback.image(
                    kind: .artwork,
                    seed: stableSeed(for: logicalName),
                    pixelSize: CGSize(width: maxPixel, height: maxPixel),
                    isDark: false,
                    themeColor: nil
                ) else {
                    return nil
                }
                imageCache.setObject(
                    CGImageBox(fallback),
                    forKey: fallbackCacheKey,
                    cost: byteCost(for: fallback)
                )
                return fallback
            }
            if !isMissing {
                Log.warning("[ArtAssets] Resource could not be decoded: \(error)", category: .theme)
            }
            return nil
        }
    }

    nonisolated func nsImage(
        logicalName: String,
        in bundle: Bundle? = nil,
        maxPixel: Int,
        fallbackToProgrammaticArt: Bool = false
    ) -> NSImage? {
        guard let cgImage = cgImage(
            logicalName: logicalName,
            in: bundle,
            maxPixel: maxPixel,
            fallbackToProgrammaticArt: fallbackToProgrammaticArt
        ) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated func xcAssetImage(
        named name: String,
        in bundle: Bundle? = nil,
        maxPixel: Int,
        fallbackToProgrammaticArt: Bool = false
    ) -> NSImage? {
        nsImage(
            logicalName: "XCAssets/\(name)",
            in: bundle,
            maxPixel: maxPixel,
            fallbackToProgrammaticArt: fallbackToProgrammaticArt
        )
    }

    nonisolated func assetURL(logicalName: String, in bundle: Bundle?) -> URL? {
        for source in candidateBundles(preferred: bundle) {
            if let url = assetFileURL(logicalName: logicalName, in: source) {
                return url
            }
        }
        return nil
    }

    nonisolated func purgeCache() {
        imageCache.removeAllObjects()
    }

    private nonisolated func loadCGImage(logicalName: String, in bundle: Bundle?, maxPixel: Int) throws -> CGImage {
        guard let url = assetURL(logicalName: logicalName, in: bundle) else {
            throw LoadError.missingFile(logicalName)
        }
        let fileData = try Data(contentsOf: url)
        let plaintext: Data
        do {
            plaintext = try ArtRuntimeLoader.shared.decrypt(
                fileData,
                logicalName: logicalName
            )
        } catch {
            throw LoadError.runtimeUnavailable(error.localizedDescription)
        }
        guard let source = CGImageSourceCreateWithData(plaintext as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw LoadError.imageDecodeFailed(logicalName)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw LoadError.imageDecodeFailed(logicalName)
        }
        return image
    }

    private nonisolated func assetFileURL(logicalName: String, in bundle: Bundle) -> URL? {
        let normalized = logicalName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let directory = (normalized as NSString).deletingLastPathComponent
        let fileName = ((normalized as NSString).lastPathComponent as NSString).deletingPathExtension
        let subdirectory = directory.isEmpty ? "EncryptedArtAssets" : "EncryptedArtAssets/\(directory)"
        return bundle.url(forResource: fileName, withExtension: "kmgasset", subdirectory: subdirectory)
    }

    private nonisolated func candidateBundles(preferred: Bundle?) -> [Bundle] {
        var bundles: [Bundle?] = [
            preferred,
            Bundle.main,
            nestedBKArtBundle(in: Bundle.main),
            Bundle(for: ArtAssetLoader.self),
            nestedBKArtBundle(in: Bundle(for: ArtAssetLoader.self)),
        ]
        if let preferred {
            bundles.append(nestedBKArtBundle(in: preferred))
        }
        return uniqueBundles(bundles)
    }

    private nonisolated func nestedBKArtBundle(in bundle: Bundle) -> Bundle? {
        let candidateNames = ["BKArt", "bkArt", "bkMask"]
        for name in candidateNames {
            if let url = bundle.url(forResource: name, withExtension: "bundle"),
               let nested = Bundle(url: url) {
                return nested
            }
        }
        return nil
    }

    private nonisolated func uniqueBundles(_ bundles: [Bundle?]) -> [Bundle] {
        bundles.compactMap { $0 }.reduce(into: [Bundle]()) { partial, item in
            if !partial.contains(where: { $0.bundleURL == item.bundleURL }) {
                partial.append(item)
            }
        }
    }

    private nonisolated func byteCost(for image: CGImage) -> Int {
        max(1, image.bytesPerRow * image.height)
    }

    private nonisolated func stableSeed(for value: String) -> UInt64 {
        value.utf8.reduce(UInt64(0xcbf29ce484222325)) { hash, byte in
            (hash ^ UInt64(byte)) &* UInt64(0x100000001b3)
        }
    }
}

struct ArtAssetImage: View {
    let name: String
    var maxPixel: Int = 1_600
    var fallbackSystemName: String = "photo"

    var body: some View {
        if let image = ArtAssetLoader.shared.xcAssetImage(
            named: name,
            maxPixel: maxPixel,
            fallbackToProgrammaticArt: true
        ) {
            Image(nsImage: image)
        } else {
            Image(systemName: fallbackSystemName)
        }
    }
}

enum ArtAssetImages {
    static let emptyLyricsName = "Empty Lyrics"

    static func image(named name: String, maxPixel: Int = 1_600, fallbackSystemName: String = "photo") -> Image {
        if let image = ArtAssetLoader.shared.xcAssetImage(
            named: name,
            maxPixel: maxPixel,
            fallbackToProgrammaticArt: true
        ) {
            return Image(nsImage: image)
        }
        return Image(systemName: fallbackSystemName)
    }
}
