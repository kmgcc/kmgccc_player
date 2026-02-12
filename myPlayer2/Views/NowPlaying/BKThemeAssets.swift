//
//  BKThemeAssets.swift
//  myPlayer2
//
//  Loads BKThemes resources from BKArt.bundle / bkMask bundle target.
//

import AppKit
import ImageIO

@MainActor
final class BKThemeAssets {
    static let shared = BKThemeAssets()

    let backgrounds: [CGImage]
    let shapes: [CGImage]
    let specialShapeScaleByIndex: [Int: CGFloat]
    let edgePinnedShapeIndices: Set<Int>
    let maskFrames: [CGImage]

    private init() {
        let bundle = Self.resolveBundle()
        print("[BKThemeAssets] Resolved bundleURL: \(bundle?.bundleURL.path ?? "nil")")

        self.backgrounds = Self.loadBackgrounds(from: bundle)
        let shapeLoadResult = Self.loadShapes(from: bundle)
        self.shapes = shapeLoadResult.images
        self.specialShapeScaleByIndex = shapeLoadResult.scaleByIndex
        self.edgePinnedShapeIndices = shapeLoadResult.edgePinnedIndices
        self.maskFrames = Self.loadMaskFrames(from: bundle)

        // Verification logs
        print("---------- BKThemeAssets Verification ----------")
        print("[BKThemeAssets] shapes.count: \(shapes.count)")
        print("[BKThemeAssets] maskFrames.count: \(maskFrames.count)")
        print("[BKThemeAssets] bk1/bk2 loaded success: \(backgrounds.count >= 2)")
        print("------------------------------------------------")
    }

    private static func resolveBundle() -> Bundle? {
        let candidateIdentifiers = [
            "kmgccc.bkMask",  // current BKArt target id in project.pbxproj
            "kmgccc.BKArt",  // historical/expected id
        ]

        for identifier in candidateIdentifiers {
            if let bundle = Bundle(identifier: identifier) {
                print("[BKThemeAssets] Found bundle by identifier(\(identifier)): \(bundle.bundleURL.path)")
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
                    print("[BKThemeAssets] Found bundle by name(\(name)) in host: \(url.path)")
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
                    if let bundle = Bundle(url: fileURL) {
                        print("[BKThemeAssets] Found bundle by scan: \(fileURL.path)")
                        return bundle
                    }
                }
            }
        }

        if Bundle.main.url(forResource: "bk1", withExtension: "png", subdirectory: "BKThemes/Backgrounds")
            != nil
        {
            print("[BKThemeAssets] Using Bundle.main directly (BKThemes folder exists in app resources)")
            return Bundle.main
        }

        print("[BKThemeAssets] Error: BKArt bundle not found! Checked identifiers, names, and scanned Resources.")
        if let resourcePath = Bundle.main.resourcePath {
            print("[BKThemeAssets] Main Bundle Resource Path: \(resourcePath)")
        }
        return nil
    }

    private static func loadBackgrounds(from bundle: Bundle?) -> [CGImage] {
        let searchBundles = [bundle, Bundle.main]
            .compactMap { $0 }
            .reduce(into: [Bundle]()) { partial, item in
                if !partial.contains(where: { $0.bundleURL == item.bundleURL }) {
                    partial.append(item)
                }
            }

        for source in searchBundles {
            let bk1URL = backgroundURL(named: "bk1", in: source)
            let bk2URL = backgroundURL(named: "bk2", in: source)

            if bk1URL != nil || bk2URL != nil {
                print("[BKThemeAssets] Background lookup bundle: \(source.bundleURL.path)")
                print("[BKThemeAssets] bk1URL: \(bk1URL?.path ?? "nil")")
                print("[BKThemeAssets] bk2URL: \(bk2URL?.path ?? "nil")")
            }

            let bk1 = bk1URL.flatMap(Self.cgImage(from:))
            let bk2 = bk2URL.flatMap(Self.cgImage(from:))
            let loaded = [bk1, bk2].compactMap { $0 }
            if !loaded.isEmpty {
                return loaded
            }
        }

        print("[BKThemeAssets] Warning: bk1/bk2 not found in any known bundle path.")
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

    private static func loadShapes(from bundle: Bundle?) -> ShapeLoadResult {
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
            print("[BKThemeAssets] 'BKThemes/Shapes' directory not found in bundle; fallback by indexed filenames.")
            for index in 1...128 {
                let shapeName = "shape\(index)"
                guard
                    let url = bundle.url(
                        forResource: shapeName, withExtension: "png", subdirectory: "BKThemes/Shapes"),
                    let image = Self.cgImage(from: url)
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

            // Filter png and sort
            let pngFiles = contents.filter { $0.pathExtension.lowercased() == "png" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            // Log for verification
            let names = pngFiles.map { $0.lastPathComponent }
            if names.contains("shape10.png") {
                print("[BKThemeAssets] Verification: Found shape10.png")
            }
            if names.contains("shape11.png") {
                print("[BKThemeAssets] Verification: Found shape11.png")
            }

            loadedShapes = []
            scaleByIndex.removeAll(keepingCapacity: true)
            edgePinnedIndices.removeAll(keepingCapacity: true)
            for url in pngFiles {
                guard let image = Self.cgImage(from: url) else { continue }
                loadedShapes.append(image)
                let fileName = url.lastPathComponent.lowercased()
                if fileName == "shape10.png" {
                    scaleByIndex[loadedShapes.count - 1] = 3.0
                    edgePinnedIndices.insert(loadedShapes.count - 1)
                }
                if fileName == "shape11.png" { scaleByIndex[loadedShapes.count - 1] = 2.0 }
            }
            if loadedShapes.isEmpty {
                for index in 1...128 {
                    let shapeName = "shape\(index)"
                    guard
                        let url = bundle.url(
                            forResource: shapeName,
                            withExtension: "png",
                            subdirectory: "BKThemes/Shapes"),
                        let image = Self.cgImage(from: url)
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
            print("[BKThemeAssets] Error scanning shapes directory: \(error)")
            for index in 1...128 {
                let shapeName = "shape\(index)"
                guard
                    let url = bundle.url(
                        forResource: shapeName, withExtension: "png", subdirectory: "BKThemes/Shapes"),
                    let image = Self.cgImage(from: url)
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

    private static func loadMaskFrames(from bundle: Bundle?) -> [CGImage] {
        guard let bundle = bundle else { return [] }
        var frames: [CGImage] = []
        var index = 0
        while true {
            let name = String(format: "frame_%02d", index)
            let url = bundle.url(
                forResource: name, withExtension: "png", subdirectory: "BKThemes/Mask")

            guard let url, let image = Self.cgImage(from: url) else {
                break
            }
            frames.append(image)
            index += 1
        }
        return frames
    }

    private static func cgImage(from url: URL) -> CGImage? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return image
    }
}
