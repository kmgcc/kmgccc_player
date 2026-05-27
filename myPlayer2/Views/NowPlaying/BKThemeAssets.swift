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
        var fileNames: [String]

        init(
            images: [CGImage],
            scaleByIndex: [Int: CGFloat],
            edgePinnedIndices: Set<Int>,
            fileNames: [String] = []
        ) {
            self.images = images
            self.scaleByIndex = scaleByIndex
            self.edgePinnedIndices = edgePinnedIndices
            self.fileNames = fileNames
        }
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
        let logicalName: String
        let plainURL: URL?
        let sourceIndex: Int?
        let fileName: String
    }

    private struct AssetEntry {
        let logicalName: String
        let plainURL: URL?
        let fileName: String
    }

    private let bundle: Bundle?
    private let backgroundEntries: [AssetEntry]
    private let shapeEntries: [ShapeEntry]
    private let maskFrameEntries: [AssetEntry]
    private let usePlainArtAssetsInDebug: Bool

    private let backgroundCache = NSCache<NSString, ImageArrayBox>()
    private let shapeCache = NSCache<NSString, ShapeLoadResultBox>()
    private let maskCache = NSCache<NSString, ImageArrayBox>()
    private let encryptedLoader = EncryptedArtAssetLoader.shared

    private static let maskProcessingContext = CIContext(options: [.cacheIntermediates: false])

    private init() {
        let resolvedBundle = Self.resolveBundle()
        let usePlainArtAssetsInDebug = Self.usePlainArtAssetsInDebug
        self.bundle = resolvedBundle
        self.usePlainArtAssetsInDebug = usePlainArtAssetsInDebug
        self.backgroundEntries = Self.resolveBackgroundEntries(
            from: resolvedBundle,
            preferPlain: usePlainArtAssetsInDebug
        )
        self.shapeEntries = Self.resolveShapeEntries(
            from: resolvedBundle,
            preferPlain: usePlainArtAssetsInDebug
        )
        self.maskFrameEntries = Self.resolveMaskFrameEntries(
            from: resolvedBundle,
            preferPlain: usePlainArtAssetsInDebug
        )

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

        let images = backgroundEntries.compactMap { downsampledImage(from: $0, maxPixel: maxPixel) }
        let box = ImageArrayBox(images: images)
        backgroundCache.setObject(box, forKey: key, cost: Self.byteCost(for: images))
        return images
    }

    var backgroundCount: Int {
        backgroundEntries.count
    }

    func background(at index: Int, maxPixel: Int) -> CGImage? {
        guard index >= 0, index < backgroundEntries.count else { return nil }

        let key = "background-\(index)-\(maxPixel)" as NSString
        if let cached = backgroundCache.object(forKey: key) {
            return cached.images.first
        }

        guard let image = downsampledImage(from: backgroundEntries[index], maxPixel: maxPixel) else {
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
        var fileNames: [String] = []

        for entry in shapeEntries {
            let asset = AssetEntry(
                logicalName: entry.logicalName,
                plainURL: entry.plainURL,
                fileName: entry.fileName
            )
            guard let image = downsampledImage(from: asset, maxPixel: maxPixel) else {
                continue
            }
            images.append(image)
            fileNames.append(entry.fileName)
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
            edgePinnedIndices: edgePinnedIndices,
            fileNames: fileNames
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

        let frames = maskFrameEntries.compactMap { entry -> CGImage? in
            guard let sampled = downsampledImage(from: entry, maxPixel: maxPixel) else {
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
        encryptedLoader.purgeCache()
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

        if EncryptedArtAssetLoader.shared.assetURL(logicalName: "BKThemes/Backgrounds/bk1", in: Bundle.main)
            != nil
        {
            return Bundle.main
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

    private static func resolveBackgroundEntries(from bundle: Bundle?, preferPlain: Bool) -> [AssetEntry] {
        let searchBundles = uniqueBundles([bundle, Bundle.main])
        let names = ["bk1", "bk2"]

        let entries = names.compactMap { name -> AssetEntry? in
            let logicalName = "BKThemes/Backgrounds/\(name)"
            let encryptedExists = searchBundles.contains {
                EncryptedArtAssetLoader.shared.assetURL(logicalName: logicalName, in: $0) != nil
            }
            let plainURL = preferPlain ? backgroundURL(named: name, in: searchBundles) : nil
            guard encryptedExists || plainURL != nil else { return nil }
            return AssetEntry(logicalName: logicalName, plainURL: plainURL, fileName: "\(name).png")
        }

        return entries
    }

    private static func backgroundURL(named name: String, in bundles: [Bundle]) -> URL? {
        for bundle in bundles {
            if let url = backgroundURL(named: name, in: bundle) {
                return url
            }
        }
        return debugPlainAssetURL(relativePath: "Backgrounds/\(name).png")
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

    private static func resolveShapeEntries(from bundle: Bundle?, preferPlain: Bool) -> [ShapeEntry] {
        let searchBundles = uniqueBundles([bundle, Bundle.main])

        if preferPlain,
           let shapesDir = debugPlainAssetURL(relativePath: "Shapes"),
            let enumerated = try? FileManager.default.contentsOfDirectory(
                at: shapesDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        {
            let entries = enumerated
                .filter { $0.pathExtension.lowercased() == "png" }
                .map {
                    ShapeEntry(
                        logicalName: "BKThemes/Shapes/\(($0.deletingPathExtension().lastPathComponent))",
                        plainURL: $0,
                        sourceIndex: shapeIndex(from: $0.lastPathComponent),
                        fileName: $0.lastPathComponent
                    )
                }
                .sorted { lhs, rhs in
                    switch (lhs.sourceIndex, rhs.sourceIndex) {
                    case let (.some(left), .some(right)):
                        return left < right
                    case (.some, .none):
                        return true
                    case (.none, .some):
                        return false
                    case (.none, .none):
                        return lhs.fileName < rhs.fileName
                    }
                }
            if !entries.isEmpty {
                return entries
            }
        }

        return (1...128).compactMap { index in
            let name = "shape\(index)"
            let logicalName = "BKThemes/Shapes/\(name)"
            let encryptedExists = searchBundles.contains {
                EncryptedArtAssetLoader.shared.assetURL(logicalName: logicalName, in: $0) != nil
            }
            let plainURL = preferPlain
                ? debugPlainAssetURL(relativePath: "Shapes/\(name).png")
                    ?? searchBundles.compactMap {
                        $0.url(
                            forResource: name,
                            withExtension: "png",
                            subdirectory: "BKThemes/Shapes"
                        )
                    }.first
                : nil
            guard encryptedExists || plainURL != nil else { return nil }
            return ShapeEntry(
                logicalName: logicalName,
                plainURL: plainURL,
                sourceIndex: index,
                fileName: "\(name).png"
            )
        }
    }

    private static func resolveMaskFrameEntries(from bundle: Bundle?, preferPlain: Bool) -> [AssetEntry] {
        let searchBundles = uniqueBundles([bundle, Bundle.main])
        var entries: [AssetEntry] = []
        var index = 0
        while true {
            let name = String(format: "frame_%02d", index)
            let logicalName = "BKThemes/Mask/\(name)"
            let encryptedExists = searchBundles.contains {
                EncryptedArtAssetLoader.shared.assetURL(logicalName: logicalName, in: $0) != nil
            }
            let plainURL = preferPlain
                ? debugPlainAssetURL(relativePath: "Mask/\(name).png")
                    ?? searchBundles.compactMap {
                        $0.url(
                            forResource: name,
                            withExtension: "png",
                            subdirectory: "BKThemes/Mask"
                        )
                    }.first
                : nil
            guard encryptedExists || plainURL != nil else {
                break
            }
            entries.append(AssetEntry(logicalName: logicalName, plainURL: plainURL, fileName: "\(name).png"))
            index += 1
        }
        return entries
    }

    private func downsampledImage(from entry: AssetEntry, maxPixel: Int) -> CGImage? {
        guard maxPixel > 0 else { return nil }
        if usePlainArtAssetsInDebug, let plainURL = entry.plainURL {
            return Self.downsampledImage(from: plainURL, maxPixel: maxPixel)
        }

        if let encrypted = encryptedLoader.cgImage(logicalName: entry.logicalName, in: bundle, maxPixel: maxPixel) {
            return encrypted
        }

        #if DEBUG
        if let plainURL = entry.plainURL {
            Log.warning(
                "[BKThemeAssets] Falling back to plaintext art asset after encrypted load failed: \(entry.logicalName)",
                category: .theme
            )
            return Self.downsampledImage(from: plainURL, maxPixel: maxPixel)
        }
        #endif

        return nil
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

    private static var usePlainArtAssetsInDebug: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["KMG_USE_PLAIN_ART_ASSETS"] != "0"
        #else
        return false
        #endif
    }

    private static func debugPlainAssetURL(relativePath: String) -> URL? {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment["KMG_ART_ASSETS_PLAIN_ROOT"]
        let roots: [URL?] = [
            environment.map { URL(fileURLWithPath: $0) },
            debugPlainBKThemesRootURL(),
        ]
        for root in roots.compactMap({ $0 }) {
            let candidate = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        #endif
        return nil
    }

    private static func debugPlainBKThemesRootURL() -> URL? {
        #if DEBUG
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            root.deleteLastPathComponent()
        }
        let candidate = root.appendingPathComponent("BKThemes")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }
        return candidate
        #else
        return nil
        #endif
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
