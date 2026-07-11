//
//  EncryptedArtAssetLoader.swift
//  myPlayer2
//
//  Loads encrypted first-party art assets from .kmgasset files.
//

import AppKit
import Foundation
import ImageIO
import SwiftUI

final class EncryptedArtAssetLoader: @unchecked Sendable {
    nonisolated static let shared = EncryptedArtAssetLoader()

    enum LoadError: Error, CustomStringConvertible {
        case missingFile(String)
        case badMagic(String)
        case unsupportedVersion(UInt8)
        case unsupportedAlgorithm(UInt8)
        case malformedHeader(String)
        case authenticationFailed(String)
        case privateRuntimeUnavailable(String)
        case imageDecodeFailed(String)

        var description: String {
            switch self {
            case .missingFile(let logicalName):
                return "missing encrypted art asset: \(logicalName)"
            case .badMagic(let logicalName):
                return "invalid encrypted art magic: \(logicalName)"
            case .unsupportedVersion(let version):
                return "unsupported encrypted art version: \(version)"
            case .unsupportedAlgorithm(let algorithm):
                return "unsupported encrypted art algorithm: \(algorithm)"
            case .malformedHeader(let logicalName):
                return "malformed encrypted art header: \(logicalName)"
            case .authenticationFailed(let logicalName):
                return "encrypted art authentication failed: \(logicalName)"
            case .privateRuntimeUnavailable(let reason):
                return "private art runtime unavailable: \(reason)"
            case .imageDecodeFailed(let logicalName):
                return "encrypted art image decode failed: \(logicalName)"
            }
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
            if !fallbackToProgrammaticArt {
                Log.error("[EncryptedArtAssetLoader] \(error)", category: .theme)
            }
            guard fallbackToProgrammaticArt else { return nil }
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
            if let url = encryptedURL(logicalName: logicalName, in: source) {
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
            plaintext = try PrivateArtRuntimeLoader.shared.decrypt(
                fileData,
                logicalName: logicalName
            )
        } catch {
            throw LoadError.privateRuntimeUnavailable(error.localizedDescription)
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

    private nonisolated func encryptedURL(logicalName: String, in bundle: Bundle) -> URL? {
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
            Bundle(for: EncryptedArtAssetLoader.self),
            nestedBKArtBundle(in: Bundle(for: EncryptedArtAssetLoader.self)),
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

struct EncryptedAssetImage: View {
    let name: String
    var maxPixel: Int = 1_600
    var fallbackSystemName: String = "photo"

    var body: some View {
        if let image = EncryptedArtAssetLoader.shared.xcAssetImage(
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

enum EncryptedAssetImages {
    static func image(named name: String, maxPixel: Int = 1_600, fallbackSystemName: String = "photo") -> Image {
        if let image = EncryptedArtAssetLoader.shared.xcAssetImage(
            named: name,
            maxPixel: maxPixel,
            fallbackToProgrammaticArt: true
        ) {
            return Image(nsImage: image)
        }
        return Image(systemName: fallbackSystemName)
    }
}
