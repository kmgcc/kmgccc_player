//
//  BKThemeAssets.swift
//  myPlayer2
//
//  kmgccc_player - Loads BKThemes resources from BKArt.bundle / BKThemes lazily.
//

import AppKit
import CoreImage
import ImageIO

final class BKThemeAssets: @unchecked Sendable {
    static let shared = BKThemeAssets()

    struct PixelBudget: Equatable {
        let background: Int
        let shape: Int
        let mask: Int
    }

    struct ShapeLoadResult {
        var images: [CGImage]
        var scaleByIndex: [Int: CGFloat]
        var edgePinnedIndices: Set<Int>
    }

    private final class ImageArrayBox: NSObject {
        let images: [CGImage]

        init(images: [CGImage]) {
            self.images = images
        }
    }

    private final class ShapeLoadResultBox: NSObject {
        let result: ShapeLoadResult

        init(result: ShapeLoadResult) {
            self.result = result
        }
    }

    private struct ShapeEntry {
        let url: URL
        let sourceIndex: Int?
    }

    private let bundle: Bundle?
    private let backgroundURLs: [URL]
    private let shapeEntries: [ShapeEntry]
    private let maskFrameURLs: [URL]

    private let backgroundCache = NSCache<NSString, ImageArrayBox>()
    private let shapeCache = NSCache<NSString, ShapeLoadResultBox>()
    private let maskCache = NSCache<NSString, ImageArrayBox>()

    private static let maskProcessingContext = CIContext(options: [.cacheIntermediates: false])

    private init() {
        let resolvedBundle = Self.resolveBundle()
        self.bundle = resolvedBundle
        self.backgroundURLs = Self.resolveBackgroundURLs(from: resolvedBundle)
        self.shapeEntries = Self.resolveShapeEntries(from: resolvedBundle)
        self.maskFrameURLs = Self.resolveMaskFrameURLs(from: resolvedBundle)

        backgroundCache.countLimit = 4
        backgroundCache.totalCostLimit = 32 * 1024 * 1024
        shapeCache.countLimit = 2
        shapeCache.totalCostLimit = 16 * 1024 * 1024
        maskCache.countLimit = 2
        maskCache.totalCostLimit = 48 * 1024 * 1024
    }

    func backgrounds(maxPixel: Int) -> [CGImage] {
        let key = "backgrounds-\(maxPixel)" as NSString
        if let cached = backgroundCache.object(forKey: key) {
            return cached.images
        }

        let images = backgroundURLs.compactMap { Self.downsampledImage(from: $0, maxPixel: maxPixel) }
        let box = ImageArrayBox(images: images)
        backgroundCache.setObject(box, forKey: key, cost: Self.byteCost(for: images))
        return images
    }

    var backgroundCount: Int {
        backgroundURLs.count
    }

    func background(at index: Int, maxPixel: Int) -> CGImage? {
        guard index >= 0, index < backgroundURLs.count else { return nil }

        let key = "background-\(index)-\(maxPixel)" as NSString
        if let cached = backgroundCache.object(forKey: key) {
            return cached.images.first
        }

        guard let image = Self.downsampledImage(from: backgroundURLs[index], maxPixel: maxPixel) else {
            return nil
        }

        let box = ImageArrayBox(images: [image])
        backgroundCache.setObject(box, forKey: key, cost: Self.byteCost(for: image))
        return image
    }

    func shapes(maxPixel: Int) -> ShapeLoadResult {
        let key = "shapes-\(maxPixel)" as NSString
        if let cached = shapeCache.object(forKey: key) {
            return cached.result
        }

        var images: [CGImage] = []
        var scaleByIndex: [Int: CGFloat] = [:]
        var edgePinnedIndices = Set<Int>()

        for entry in shapeEntries {
            guard let image = Self.downsampledImage(from: entry.url, maxPixel: maxPixel) else {
                continue
            }
            images.append(image)
            if entry.sourceIndex == 10 {
                scaleByIndex[images.count - 1] = 3.0
                edgePinnedIndices.insert(images.count - 1)
            }
            if entry.sourceIndex == 11 {
                scaleByIndex[images.count - 1] = 2.0
            }
        }

        let result = ShapeLoadResult(
            images: images,
            scaleByIndex: scaleByIndex,
            edgePinnedIndices: edgePinnedIndices
        )
        let box = ShapeLoadResultBox(result: result)
        shapeCache.setObject(box, forKey: key, cost: Self.byteCost(for: images))
        return result
    }

    func maskFrames(maxPixel: Int) -> [CGImage] {
        let key = "mask-\(maxPixel)" as NSString
        if let cached = maskCache.object(forKey: key) {
            return cached.images
        }

        let frames = maskFrameURLs.compactMap { url -> CGImage? in
            guard let sampled = Self.downsampledImage(from: url, maxPixel: maxPixel) else {
                return nil
            }
            return Self.maskAlphaImage(from: sampled) ?? sampled
        }

        let box = ImageArrayBox(images: frames)
        maskCache.setObject(box, forKey: key, cost: Self.byteCost(for: frames))
        return frames
    }

    func cachedMaskFrames(maxPixel: Int) -> [CGImage]? {
        let key = "mask-\(maxPixel)" as NSString
        return maskCache.object(forKey: key)?.images
    }

    func purgeTransientCaches() {
        backgroundCache.removeAllObjects()
        shapeCache.removeAllObjects()
        maskCache.removeAllObjects()
        Self.maskProcessingContext.clearCaches()
    }

    private static func resolveBundle() -> Bundle? {
        let candidateIdentifiers = [
            "kmgccc.bkMask",
            "kmgccc.BKArt",
        ]

        for identifier in candidateIdentifiers {
            if let bundle = Bundle(identifier: identifier) {
                return bundle
            }
        }

        let candidateNames = ["BKArt", "bkArt", "bkMask"]
        let candidateHosts = [Bundle.main, Bundle(for: BKThemeAssets.self)]
        for host in candidateHosts {
            for name in candidateNames {
                if let url = host.url(forResource: name, withExtension: "bundle"),
                    let bundle = Bundle(url: url)
                {
                    return bundle
                }
            }
        }

        if Bundle.main.url(forResource: "bk1", withExtension: "png", subdirectory: "BKThemes/Backgrounds")
            != nil
        {
            return Bundle.main
        }

        return nil
    }

    private static func uniqueBundles(_ bundles: [Bundle?]) -> [Bundle] {
        bundles
            .compactMap { $0 }
            .reduce(into: [Bundle]()) { partial, item in
                if !partial.contains(where: { $0.bundleURL == item.bundleURL }) {
                    partial.append(item)
                }
            }
    }

    private static func resolveBackgroundURLs(from bundle: Bundle?) -> [URL] {
        let searchBundles = uniqueBundles([bundle, Bundle.main])

        for source in searchBundles {
            let urls = ["bk1", "bk2"].compactMap { backgroundURL(named: $0, in: source) }
            if !urls.isEmpty {
                return urls
            }
        }

        return []
    }

    private static func backgroundURL(named name: String, in bundle: Bundle) -> URL? {
        let subdirs: [String?] = ["BKThemes/Backgrounds", "Backgrounds", "BKThemes", nil]
        for subdir in subdirs {
            if let subdir, let url = bundle.url(forResource: name, withExtension: "png", subdirectory: subdir)
            {
                return url
            }
            if subdir == nil, let url = bundle.url(forResource: name, withExtension: "png") {
                return url
            }
        }
        return nil
    }

    private static func resolveShapeEntries(from bundle: Bundle?) -> [ShapeEntry] {
        guard let bundle else { return [] }

        if let shapesDir = bundle.url(forResource: "Shapes", withExtension: nil, subdirectory: "BKThemes"),
            let enumerated = try? FileManager.default.contentsOfDirectory(
                at: shapesDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        {
            let entries = enumerated
                .filter { $0.pathExtension.lowercased() == "png" }
                .map { ShapeEntry(url: $0, sourceIndex: shapeIndex(from: $0.lastPathComponent)) }
                .sorted { lhs, rhs in
                    switch (lhs.sourceIndex, rhs.sourceIndex) {
                    case let (.some(left), .some(right)):
                        return left < right
                    case (.some, .none):
                        return true
                    case (.none, .some):
                        return false
                    case (.none, .none):
                        return lhs.url.lastPathComponent < rhs.url.lastPathComponent
                    }
                }
            if !entries.isEmpty {
                return entries
            }
        }

        return (1...128).compactMap { index in
            guard
                let url = bundle.url(
                    forResource: "shape\(index)",
                    withExtension: "png",
                    subdirectory: "BKThemes/Shapes"
                )
            else {
                return nil
            }
            return ShapeEntry(url: url, sourceIndex: index)
        }
    }

    private static func resolveMaskFrameURLs(from bundle: Bundle?) -> [URL] {
        let searchBundles = uniqueBundles([bundle, Bundle.main])
        for source in searchBundles {
            var urls: [URL] = []
            var index = 0
            while true {
                let name = String(format: "frame_%02d", index)
                guard let url = source.url(
                    forResource: name,
                    withExtension: "png",
                    subdirectory: "BKThemes/Mask"
                ) else {
                    break
                }
                urls.append(url)
                index += 1
            }
            if !urls.isEmpty {
                return urls
            }
        }
        return []
    }

    private static func downsampledImage(from url: URL, maxPixel: Int) -> CGImage? {
        guard maxPixel > 0 else { return nil }
        guard
            let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func maskAlphaImage(from image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let alphaMask = input.applyingFilter("CIMaskToAlpha")
        return maskProcessingContext.createCGImage(alphaMask, from: alphaMask.extent)
    }

    private static func shapeIndex(from fileName: String) -> Int? {
        let stem = fileName
            .lowercased()
            .replacingOccurrences(of: ".png", with: "")
        guard stem.hasPrefix("shape") else { return nil }
        return Int(stem.dropFirst("shape".count))
    }

    private static func byteCost(for images: [CGImage]) -> Int {
        images.reduce(0) { partial, image in
            partial + byteCost(for: image)
        }
    }

    private static func byteCost(for image: CGImage) -> Int {
        max(1, image.bytesPerRow * image.height)
    }
}
