//
//  BKThemeAssets.swift
//  myPlayer2
//
//  Loads BKThemes resources from BKArt.bundle.
//

import AppKit
import ImageIO

@MainActor
final class BKThemeAssets {
    static let shared = BKThemeAssets()
    private static let bundleIdentifier = "kmgccc.BKArt"

    let backgrounds: [CGImage]
    let shapes: [CGImage]
    let maskFrames: [CGImage]

    private init() {
        let bundle = Self.resolveBundle()
        self.backgrounds = Self.loadBackgrounds(from: bundle)
        self.shapes = Self.loadShapes(from: bundle)
        self.maskFrames = Self.loadMaskFrames(from: bundle)
    }

    private static func resolveBundle() -> Bundle? {
        if let identified = Bundle(identifier: bundleIdentifier) {
            print("[BKThemeAssets] bundle(identifier:) found: \(identified.bundleURL.path)")
            return identified
        }
        if let bundledURL = Bundle.main.url(forResource: "BKArt", withExtension: "bundle"),
            let bundle = Bundle(url: bundledURL)
        {
            print("[BKThemeAssets] fallback bundle URL found: \(bundle.bundleURL.path)")
            return bundle
        }
        print("[BKThemeAssets] fallback to Bundle.main: \(Bundle.main.bundleURL.path)")
        return Bundle.main
    }

    private static func loadBackgrounds(from bundle: Bundle?) -> [CGImage] {
        let bk1URL = bundle?.url(
            forResource: "bk1",
            withExtension: "png",
            subdirectory: "BKThemes/Backgrounds")
        let bk2URL = bundle?.url(
            forResource: "bk2",
            withExtension: "png",
            subdirectory: "BKThemes/Backgrounds")

        print("[BKThemeAssets] bk1 url(forResource:): \(bk1URL?.path ?? "nil")")
        print("[BKThemeAssets] bk2 url(forResource:): \(bk2URL?.path ?? "nil")")

        let bk1 = bk1URL.flatMap(Self.cgImage(from:))
        let bk2 = bk2URL.flatMap(Self.cgImage(from:))

        print("[BKThemeAssets] bk1 loaded: \(bk1 != nil), bk2 loaded: \(bk2 != nil)")

        return [bk1, bk2].compactMap { $0 }
    }

    private static func loadShapes(from bundle: Bundle?) -> [CGImage] {
        let loaded: [CGImage] = (1...9).compactMap { index in
            let url = bundle?.url(
                forResource: "shape\(index)",
                withExtension: "png",
                subdirectory: "BKThemes/Shapes")
            if index == 1 || index == 9 {
                print("[BKThemeAssets] shape\(index) url(forResource:): \(url?.path ?? "nil")")
            }
            guard let url else { return nil }
            return Self.cgImage(from: url)
        }
        print("[BKThemeAssets] shapes.count: \(loaded.count)")
        return loaded
    }

    private static func loadMaskFrames(from bundle: Bundle?) -> [CGImage] {
        var frames: [CGImage] = []
        var index = 0
        while true {
            let name = String(format: "frame_%02d", index)
            let url = bundle?.url(
                forResource: name,
                withExtension: "png",
                subdirectory: "BKThemes/Mask")

            if index == 0 {
                print("[BKThemeAssets] \(name) url(forResource:): \(url?.path ?? "nil")")
            }

            guard let url, let image = Self.cgImage(from: url) else {
                break
            }

            frames.append(image)
            index += 1
        }
        print("[BKThemeAssets] maskFrames.count: \(frames.count)")
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
