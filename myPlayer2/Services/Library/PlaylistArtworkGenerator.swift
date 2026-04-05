//
//  PlaylistArtworkGenerator.swift
//  myPlayer2
//
//  Generates deterministic playlist cover art by recoloring a grayscale base image
//  with colors extracted from the playlist's track artworks.
//  Generation is off-thread; result is cached by (playlistID, contentSignature).
//

import AppKit

actor PlaylistArtworkGenerator {

    static let shared = PlaylistArtworkGenerator()

    private var cache: [UUID: (signature: String, image: NSImage)] = [:]

    // MARK: - Public API

    /// Returns cached or newly generated artwork for a playlist.
    /// Safe to call from MainActor; dispatches generation off-thread.
    func artwork(for playlist: Playlist, tracks: [Track]) async -> NSImage? {
        let signature = contentSignature(tracks: tracks)
        if let cached = cache[playlist.id], cached.signature == signature {
            return cached.image
        }

        let playlistID = playlist.id
        // Snapshot track data for off-thread use (IDs + artworkData only)
        let snapshots: [(id: UUID, artworkData: Data?)] = tracks.map {
            (id: $0.id, artworkData: $0.artworkData)
        }

        let result = await Task.detached(priority: .userInitiated) {
            PlaylistArtworkGenerator.generate(playlistID: playlistID, snapshots: snapshots)
        }.value

        if let result {
            cache[playlistID] = (signature, result)
        }
        return result
    }

    // MARK: - Cache

    func invalidate(playlistID: UUID) {
        cache.removeValue(forKey: playlistID)
    }

    // MARK: - Generation (nonisolated, runs off main thread)

    private static nonisolated func generate(
        playlistID: UUID,
        snapshots: [(id: UUID, artworkData: Data?)]
    ) -> NSImage? {
        let hash = stableHash(for: playlistID.uuidString)

        // Step 1: Select base image
        let baseNames = ["cov1", "cov2", "cov3"]
        let baseName = baseNames[hash % 3]
        guard let baseImage = NSImage(named: baseName) else { return nil }

        // Step 2: Sample track indices deterministically
        let artSnapshots = snapshots.filter { $0.artworkData != nil }
        guard !artSnapshots.isEmpty else {
            return tintedFallback(baseImage: baseImage)
        }

        let sampleCount = min(5, artSnapshots.count)
        let indices = sampleIndices(from: hash, count: sampleCount, total: artSnapshots.count)

        // Step 3: Extract colors from sampled artworks
        var colors: [NSColor] = []
        for idx in indices {
            guard let data = artSnapshots[idx].artworkData else { continue }
            let palette = ArtworkColorExtractor.uiThemePalette(from: data, maxColors: 3)
            colors.append(contentsOf: palette)
        }
        guard !colors.isEmpty else {
            return tintedFallback(baseImage: baseImage)
        }

        // Step 4: Sort by luminance (darkest → lightest)
        let sorted = colors.sorted { luminance($0) < luminance($1) }

        // Step 5: Deduplicate nearby luminance values, keep up to 5
        let representative = deduped(sorted, maxCount: 5)

        // Step 6: Build 256-entry gradient LUT
        let lut = buildLUT(from: representative)

        // Step 7: Recolor
        return recolor(baseImage: baseImage, lut: lut) ?? tintedFallback(baseImage: baseImage)
    }

    // MARK: - Stable Hash (DJB2, launch-stable)

    static nonisolated func stableHash(for string: String) -> Int {
        var hash: Int = 5381
        for byte in string.utf8 {
            hash = (hash &* 33) ^ Int(byte)
        }
        return abs(hash)
    }

    // MARK: - Sample Index Selection

    private static nonisolated func sampleIndices(from hash: Int, count: Int, total: Int) -> [Int] {
        var result: [Int] = []
        var seen = Set<Int>()
        var h = hash
        while result.count < count {
            let idx = abs(h) % total
            if seen.insert(idx).inserted {
                result.append(idx)
            }
            h = (h &* 1_664_525) &+ 1_013_904_223  // LCG step
        }
        return result
    }

    // MARK: - Content Signature

    private nonisolated func contentSignature(tracks: [Track]) -> String {
        let sortedIDs = tracks.map(\.id.uuidString).sorted().joined()
        return String(PlaylistArtworkGenerator.stableHash(for: sortedIDs))
    }

    // MARK: - Luminance

    private static nonisolated func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    // MARK: - Dedup by luminance proximity

    private static nonisolated func deduped(_ colors: [NSColor], maxCount: Int) -> [NSColor] {
        var result: [NSColor] = []
        for color in colors {
            let lum = luminance(color)
            if !result.contains(where: { abs(luminance($0) - lum) < 0.08 }) {
                result.append(color)
                if result.count == maxCount { break }
            }
        }
        return result.isEmpty ? Array(colors.prefix(maxCount)) : result
    }

    // MARK: - LUT Construction

    private static nonisolated func buildLUT(from colors: [NSColor]) -> [NSColor] {
        guard !colors.isEmpty else { return Array(repeating: .gray, count: 256) }
        var lut = [NSColor](repeating: .black, count: 256)
        for i in 0..<256 {
            let t = CGFloat(i) / 255.0
            lut[i] = interpolateColor(t: t, stops: colors)
        }
        return lut
    }

    private static nonisolated func interpolateColor(t: CGFloat, stops: [NSColor]) -> NSColor {
        let count = stops.count
        guard count > 1 else { return stops[0] }
        let scaled = t * CGFloat(count - 1)
        let lower = min(Int(scaled), count - 2)
        let upper = lower + 1
        let localT = scaled - CGFloat(lower)
        return blend(stops[lower], stops[upper], t: localT)
    }

    private static nonisolated func blend(_ a: NSColor, _ b: NSColor, t: CGFloat) -> NSColor {
        guard let ac = a.usingColorSpace(.deviceRGB),
              let bc = b.usingColorSpace(.deviceRGB) else { return a }
        return NSColor(
            calibratedRed: ac.redComponent + (bc.redComponent - ac.redComponent) * t,
            green: ac.greenComponent + (bc.greenComponent - ac.greenComponent) * t,
            blue: ac.blueComponent + (bc.blueComponent - ac.blueComponent) * t,
            alpha: 1.0
        )
    }

    // MARK: - Pixel Recolor

    private static nonisolated func recolor(baseImage: NSImage, lut: [NSColor]) -> NSImage? {
        guard let cgBase = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = cgBase.width
        let height = cgBase.height
        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)

        guard let ctx = CGContext(
            data: &pixelData,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cgBase, in: CGRect(x: 0, y: 0, width: width, height: height))

        for i in stride(from: 0, to: pixelData.count, by: 4) {
            let a = CGFloat(pixelData[i + 3]) / 255.0
            guard a > 0 else { continue }
            let r = CGFloat(pixelData[i]) / (255.0 * a)
            let g = CGFloat(pixelData[i + 1]) / (255.0 * a)
            let b = CGFloat(pixelData[i + 2]) / (255.0 * a)
            let luma = min(1.0, 0.2126 * r + 0.7152 * g + 0.0722 * b)
            let lutIdx = min(255, Int(luma * 255))
            guard let mapped = lut[lutIdx].usingColorSpace(.deviceRGB) else { continue }
            pixelData[i]     = UInt8(min(255, mapped.redComponent   * a * 255))
            pixelData[i + 1] = UInt8(min(255, mapped.greenComponent * a * 255))
            pixelData[i + 2] = UInt8(min(255, mapped.blueComponent  * a * 255))
            // alpha unchanged
        }

        guard let outCG = ctx.makeImage() else { return nil }
        let result = NSImage(size: baseImage.size)
        result.addRepresentation(NSBitmapImageRep(cgImage: outCG))
        return result
    }

    // MARK: - Fallback

    private static nonisolated func tintedFallback(baseImage: NSImage) -> NSImage {
        let size = baseImage.size
        guard let cgBase = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return baseImage
        }
        let result = NSImage(size: size)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        baseImage.draw(in: NSRect(origin: .zero, size: size))
        NSColor.systemIndigo.withAlphaComponent(0.45).setFill()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        result.unlockFocus()
        _ = cgBase  // suppress unused warning
        return result
    }
}
