//
//  BKThemeAssets.swift
//  myPlayer2
//
//  Loads BKThemes resources from BKArt.bundle / bkMask bundle target.
//

import AppKit
import CoreImage
import ImageIO

@MainActor
final class BKThemeAssets {
    static let shared = BKThemeAssets()

    let backgrounds: [CGImage]
    let shapes: [CGImage]
    let specialShapeScaleByIndex: [Int: CGFloat]
    let edgePinnedShapeIndices: Set<Int>
    let maskFrames: [CGImage]

    private struct PixelBudget {
        let background: Int
        let shape: Int
        let mask: Int
    }

    private static let maskProcessingContext = CIContext(options: [.cacheIntermediates: false])

    private init() {
        let bundle = Self.resolveBundle()
        let budget = Self.pixelBudget()

        self.backgrounds = Self.loadBackgrounds(from: bundle, budget: budget)
        let shapeLoadResult = Self.loadShapes(from: bundle, budget: budget)
        self.shapes = shapeLoadResult.images
        self.specialShapeScaleByIndex = shapeLoadResult.scaleByIndex
        self.edgePinnedShapeIndices = shapeLoadResult.edgePinnedIndices
        self.maskFrames = Self.loadMaskFrames(from: bundle, budget: budget)
    }

    private static func resolveBundle() -> Bundle? {
        let candidateIdentifiers = [
            "kmgccc.bkMask",
            "kmgccc.BKArt",
        ]

        for identifier in candidateIdentifiers {
            if let bundle = Bundle(identifier: identifier) { return bundle }
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

        if let resourcesURL = Bundle.main.resourceURL {
            if let enumerator = FileManager.default.enumerator(
                at: resourcesURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                while let fileURL = enumerator.nextObject() as? URL {
                    guard fileURL.pathExtension.lowercased() == "bundle" else { continue }
                    let lowerName = fileURL.lastPathComponent.lowercased()
                    guard lowerName.contains("bkart") || lowerName.contains("bkmask") else { continue }
                    if let bundle = Bundle(url: fileURL) { return bundle }
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

    private static func pixelBudget() -> PixelBudget {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let maxPoints = NSScreen.screens
            .map { max($0.frame.width, $0.frame.height) }
            .max() ?? 1512
        let nativePixel = Int((maxPoints * scale).rounded())
        let background = min(max(nativePixel, 1024), 2048)
        let shape = min(max(background / 2, 384), 1024)
        return PixelBudget(background: background, shape: shape, mask: background)
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

    private static func loadBackgrounds(from bundle: Bundle?, budget: PixelBudget) -> [CGImage] {
        let searchBundles = uniqueBundles([bundle, Bundle.main])

        for source in searchBundles {
            let bk1URL = backgroundURL(named: "bk1", in: source)
            let bk2URL = backgroundURL(named: "bk2", in: source)

            let bk1 = bk1URL.flatMap { downsampledImage(from: $0, maxPixel: budget.background) }
            let bk2 = bk2URL.flatMap { downsampledImage(from: $0, maxPixel: budget.background) }
            let loaded = [bk1, bk2].compactMap { $0 }
            if !loaded.isEmpty {
                return loaded
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

    private struct ShapeLoadResult {
        var images: [CGImage]
        var scaleByIndex: [Int: CGFloat]
        var edgePinnedIndices: Set<Int>
    }

    private static func loadShapes(from bundle: Bundle?, budget: PixelBudget) -> ShapeLoadResult {
        guard let bundle = bundle else {
            return ShapeLoadResult(images: [], scaleByIndex: [:], edgePinnedIndices: [])
        }
        var loadedShapes: [CGImage] = []
        var scaleByIndex: [Int: CGFloat] = [:]
        var edgePinnedIndices = Set<Int>()

        guard
            let shapesDir = bundle.url(
                forResource: "Shapes", withExtension: nil, subdirectory: "BKThemes")
        else {
            for index in 1...128 {
                let shapeName = "shape\(index)"
                guard
                    let url = bundle.url(
                        forResource: shapeName, withExtension: "png", subdirectory: "BKThemes/Shapes"),
                    let image = downsampledImage(from: url, maxPixel: budget.shape)
                else { continue }
                loadedShapes.append(image)
                if index == 10 {
                    scaleByIndex[loadedShapes.count - 1] = 3.0
                    edgePinnedIndices.insert(loadedShapes.count - 1)
                }
                if index == 11 { scaleByIndex[loadedShapes.count - 1] = 2.0 }
            }
            return ShapeLoadResult(
                images: loadedShapes,
                scaleByIndex: scaleByIndex,
                edgePinnedIndices: edgePinnedIndices
            )
        }

        do {
            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(
                at: shapesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

            let pngFiles = contents
                .filter { $0.pathExtension.lowercased() == "png" }
                .map { (url: $0, index: shapeIndex(from: $0.lastPathComponent)) }
                .sorted { lhs, rhs in
                    switch (lhs.index, rhs.index) {
                    case let (.some(li), .some(ri)):
                        return li < ri
                    case (.some, .none):
                        return true
                    case (.none, .some):
                        return false
                    case (.none, .none):
                        return lhs.url.lastPathComponent < rhs.url.lastPathComponent
                    }
                }

            loadedShapes = []
            scaleByIndex.removeAll(keepingCapacity: true)
            edgePinnedIndices.removeAll(keepingCapacity: true)
            for entry in pngFiles {
                guard let image = downsampledImage(from: entry.url, maxPixel: budget.shape) else {
                    continue
                }
                loadedShapes.append(image)
                if entry.index == 10 {
                    scaleByIndex[loadedShapes.count - 1] = 3.0
                    edgePinnedIndices.insert(loadedShapes.count - 1)
                }
                if entry.index == 11 { scaleByIndex[loadedShapes.count - 1] = 2.0 }
            }
            if loadedShapes.isEmpty {
                for index in 1...128 {
                    let shapeName = "shape\(index)"
                    guard
                        let url = bundle.url(
                            forResource: shapeName,
                            withExtension: "png",
                            subdirectory: "BKThemes/Shapes"),
                        let image = downsampledImage(from: url, maxPixel: budget.shape)
                    else { continue }
                    loadedShapes.append(image)
                    if index == 10 {
                        scaleByIndex[loadedShapes.count - 1] = 3.0
                        edgePinnedIndices.insert(loadedShapes.count - 1)
                    }
                    if index == 11 { scaleByIndex[loadedShapes.count - 1] = 2.0 }
                }
            }
            return ShapeLoadResult(
                images: loadedShapes,
                scaleByIndex: scaleByIndex,
                edgePinnedIndices: edgePinnedIndices
            )
        } catch {
            for index in 1...128 {
                let shapeName = "shape\(index)"
                guard
                    let url = bundle.url(
                        forResource: shapeName, withExtension: "png", subdirectory: "BKThemes/Shapes"),
                    let image = downsampledImage(from: url, maxPixel: budget.shape)
                else { continue }
                loadedShapes.append(image)
                if index == 10 {
                    scaleByIndex[loadedShapes.count - 1] = 3.0
                    edgePinnedIndices.insert(loadedShapes.count - 1)
                }
                if index == 11 { scaleByIndex[loadedShapes.count - 1] = 2.0 }
            }
            return ShapeLoadResult(
                images: loadedShapes,
                scaleByIndex: scaleByIndex,
                edgePinnedIndices: edgePinnedIndices
            )
        }
    }

    private static func loadMaskFrames(from bundle: Bundle?, budget: PixelBudget) -> [CGImage] {
        let searchBundles = uniqueBundles([bundle, Bundle.main])
        var frames: [CGImage] = []
        for source in searchBundles {
            frames.removeAll(keepingCapacity: true)
            var index = 0
            while true {
                let name = String(format: "frame_%02d", index)
                let url = source.url(
                    forResource: name, withExtension: "png", subdirectory: "BKThemes/Mask")

                guard
                    let url,
                    let sampled = downsampledImage(from: url, maxPixel: budget.mask)
                else {
                    break
                }
                frames.append(maskAlphaImage(from: sampled) ?? sampled)
                index += 1
            }
            if !frames.isEmpty { return frames }
        }
        return frames
    }

    private static func downsampledImage(from url: URL, maxPixel: Int) -> CGImage? {
        guard maxPixel > 0 else { return nil }
        guard
            let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }

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
}
