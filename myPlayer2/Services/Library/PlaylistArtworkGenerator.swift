//
//  PlaylistArtworkGenerator.swift
//  myPlayer2
//
//  Deterministic playlist artwork generation plus canonical detail-header artwork resolution.
//

import AppKit

struct PlaylistArtworkSnapshot: Sendable {
    let id: UUID
    let artworkData: Data?
    let artworkFileURL: URL?

    @MainActor
    init(track: Track) {
        self.id = track.id
        self.artworkData = track.artworkData
        self.artworkFileURL = track.resolvedArtworkURL()
    }

    nonisolated init(id: UUID, artworkData: Data?, artworkFileURL: URL? = nil) {
        self.id = id
        self.artworkData = artworkData
        self.artworkFileURL = artworkFileURL
    }
}

actor PlaylistArtworkGenerator {

    static let shared = PlaylistArtworkGenerator()

    /// Generates artwork with optional variation seed for manual regeneration.
    /// - variationSeed: when nil, uses deterministic hash from playlistID (for initial generation).
    ///              when provided, uses that seed for varied regeneration (for manual refresh).
    func generateArtwork(
        playlistID: UUID,
        snapshots: [PlaylistArtworkSnapshot],
        variationSeed: Int? = nil
    ) async -> NSImage? {
        return await Task.detached(priority: .userInitiated) {
            PlaylistArtworkGenerator.generate(
                playlistID: playlistID,
                snapshots: snapshots,
                variationSeed: variationSeed
            )
        }.value
    }

    func generateArtwork(
        playlistID: UUID,
        snapshots: [(id: UUID, artworkData: Data?)],
        variationSeed: Int? = nil
    ) async -> NSImage? {
        await generateArtwork(
            playlistID: playlistID,
            snapshots: snapshots.map { PlaylistArtworkSnapshot(id: $0.id, artworkData: $0.artworkData) },
            variationSeed: variationSeed
        )
    }

    // MARK: - Generation (nonisolated, runs off main thread)

    private static nonisolated func generate(
        playlistID: UUID,
        snapshots: [PlaylistArtworkSnapshot],
        variationSeed: Int? = nil
    ) -> NSImage? {
        // Use variation seed if provided (manual regenerate), otherwise deterministic hash
        let hash = variationSeed ?? stableHash(for: playlistID.uuidString)

        let baseImage = loadBaseImage(hash: hash)
        guard let baseImage else {
            logGenerator("playlistID=\(playlistID) phase=base-image-load-failed allBasesFailed=true")
            return nil
        }

        let artSnapshots = snapshots.filter {
            ($0.artworkData?.isEmpty == false) || $0.artworkFileURL != nil
        }
        guard !artSnapshots.isEmpty else {
            let baseNames = ["cov1", "cov2", "cov3", "cov4"]
            logGenerator("playlistID=\(playlistID) phase=empty-playlist-fallback baseName=\(baseNames[hash % 4])")
            return tintedFallback(baseImage: baseImage)
        }

        // For manual regeneration with variation, use different sample strategy
        let sampleCount = min(5, artSnapshots.count)
        let indices: [Int]
        if let seed = variationSeed {
            // Use seeded random for varied selection
            indices = variedSampleIndices(seed: seed, count: sampleCount, total: artSnapshots.count)
        } else {
            // Use deterministic hash-based selection
            indices = sampleIndices(from: hash, count: sampleCount, total: artSnapshots.count)
        }

        var colors: [NSColor] = []
        for idx in indices {
            guard let data = artworkData(for: artSnapshots[idx]) else { continue }
            let palette = ArtworkColorExtractor.uiThemePalette(from: data, maxColors: 3)
            colors.append(contentsOf: palette)
        }
        guard !colors.isEmpty else {
            logGenerator("playlistID=\(playlistID) phase=no-colors fallback=tinted")
            return tintedFallback(baseImage: baseImage)
        }

        let sorted = colors.sorted { luminance($0) < luminance($1) }
        let representative = deduped(sorted, maxCount: 5)
        let normalized = ensureLuminanceSpread(representative)
        let lut = buildLUT(from: normalized)
        return recolor(baseImage: baseImage, lut: lut) ?? tintedFallback(baseImage: baseImage)
    }

    private static nonisolated func artworkData(for snapshot: PlaylistArtworkSnapshot) -> Data? {
        if let artworkData = snapshot.artworkData, !artworkData.isEmpty {
            return artworkData
        }
        guard let artworkFileURL = snapshot.artworkFileURL else { return nil }
        return try? Data(contentsOf: artworkFileURL)
    }

    // MARK: - Stable Hash

    static nonisolated func stableHash(for string: String) -> Int {
        var hash: Int = 5381
        for byte in string.utf8 {
            hash = (hash &* 33) ^ Int(byte)
        }
        return abs(hash)
    }

    private static nonisolated func sampleIndices(from hash: Int, count: Int, total: Int) -> [Int] {
        var result: [Int] = []
        var seen = Set<Int>()
        var h = hash
        while result.count < count {
            let idx = abs(h) % total
            if seen.insert(idx).inserted {
                result.append(idx)
            }
            h = (h &* 1_664_525) &+ 1_013_904_223
        }
        return result
    }

    /// Varied sample indices for manual regeneration - produces different results each time.
    private static nonisolated func variedSampleIndices(seed: Int, count: Int, total: Int) -> [Int] {
        var result: [Int] = []
        var seen = Set<Int>()
        // Use a different hash mixing for variety
        var h = seed &+ 0x9E3779B9  // Golden ratio additive
        while result.count < count {
            // LCG parameters for good distribution
            h = (h &* 1_103_515_245) &+ 12_345
            let idx = abs(h) % total
            if seen.insert(idx).inserted {
                result.append(idx)
            }
        }
        return result
    }

    static func contentSignature(tracks: [Track]) -> String {
        let sortedIDs = tracks.map(\.id.uuidString).sorted().joined()
        return String(stableHash(for: sortedIDs))
    }

    private static nonisolated func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

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

    /// Ensures the palette spans at least a minimum luminance range.
    /// If all colors collapse into a narrow band, injects a dark and light anchor
    /// so the grayscale base pattern remains visible after recoloring.
    private static nonisolated func ensureLuminanceSpread(_ colors: [NSColor]) -> [NSColor] {
        guard !colors.isEmpty else { return colors }
        let lums = colors.map { luminance($0) }
        let minLum = lums.min()!
        let maxLum = lums.max()!
        let spread = maxLum - minLum

        // If spread is already decent, return as-is
        if spread >= 0.25 { return colors }

        // Derive dark and light anchors from the midpoint color
        let midColor = colors[colors.count / 2]
        guard let rgb = midColor.usingColorSpace(.deviceRGB) else { return colors }

        let darkAnchor = NSColor(
            calibratedRed: rgb.redComponent * 0.25,
            green: rgb.greenComponent * 0.25,
            blue: rgb.blueComponent * 0.25,
            alpha: 1
        )
        let lightAnchor = NSColor(
            calibratedRed: min(1, rgb.redComponent * 0.5 + 0.5),
            green: min(1, rgb.greenComponent * 0.5 + 0.5),
            blue: min(1, rgb.blueComponent * 0.5 + 0.5),
            alpha: 1
        )

        var result = [darkAnchor] + colors + [lightAnchor]
        result.sort { luminance($0) < luminance($1) }
        return result
    }

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

    private static nonisolated func recolor(baseImage: NSImage, lut: [NSColor]) -> NSImage? {
        guard let tiff = baseImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else { return nil }

        let out = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let output = out else { return nil }

        for y in 0..<height {
            for x in 0..<width {
                guard let src = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let gray = Int(max(0, min(255, round(src.redComponent * 255))))
                let mapped = lut[gray].usingColorSpace(.deviceRGB) ?? .gray
                let alpha = src.alphaComponent
                output.setColor(
                    NSColor(
                        calibratedRed: mapped.redComponent,
                        green: mapped.greenComponent,
                        blue: mapped.blueComponent,
                        alpha: alpha
                    ),
                    atX: x,
                    y: y
                )
            }
        }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(output)
        return image
    }

    /// Loads a deterministic grayscale base image, trying all four bases if the primary fails.
    private static nonisolated func loadBaseImage(hash: Int) -> NSImage? {
        let baseNames = ["cov1", "cov2", "cov3", "cov4"]
        let primaryIndex = hash % 4
        // Try primary first, then the others as fallbacks
        for offset in 0..<4 {
            let name = baseNames[(primaryIndex + offset) % 4]
            if let image = NSImage(named: name) {
                return image
            }
        }
        return nil
    }

    private static nonisolated func tintedFallback(baseImage: NSImage) -> NSImage? {
        let fallbackColors: [NSColor] = [
            NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.32, alpha: 1),   // dark anchor
            NSColor(calibratedRed: 0.22, green: 0.36, blue: 0.78, alpha: 1),
            NSColor(calibratedRed: 0.42, green: 0.58, blue: 0.88, alpha: 1),
            NSColor(calibratedRed: 0.72, green: 0.80, blue: 0.95, alpha: 1),
            NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.98, alpha: 1),   // light anchor
        ]
        let lut = buildLUT(from: fallbackColors)
        let result = recolor(baseImage: baseImage, lut: lut)
        if result == nil {
            logGenerator("phase=tinted-fallback-recolor-failed")
        }
        return result
    }

    private static nonisolated func logGenerator(_ message: String) {
        print("🎨 [PlaylistArtworkGenerator] \(message)")
    }
}

@MainActor
final class DetailHeaderArtworkResolver {

    nonisolated static let shared = DetailHeaderArtworkResolver()

    private nonisolated init() {}

    private let libraryService = LocalLibraryService.shared
    private let generator = PlaylistArtworkGenerator.shared

    func resolveImmediately(for request: DetailHeaderArtworkRequest) -> ResolvedHeaderArtwork? {
        switch request {
        case .playlist(let selectionIdentity, let playlistID, _):
            let record = libraryService.loadPlaylistArtworkRecord(playlistID: playlistID)

            if let custom = record.customArtwork {
                return ResolvedHeaderArtwork(
                    selectionIdentity: selectionIdentity,
                    selectionType: .playlist,
                    source: .custom,
                    image: custom.image,
                    fileURL: custom.fileURL,
                    generationSignature: nil
                )
            }

            // Rule: Once generated artwork exists, it stays stable regardless of content changes.
            // Only manual user action can change it (import custom or explicit regenerate).
            if let generated = record.generatedArtwork {
                return ResolvedHeaderArtwork(
                    selectionIdentity: selectionIdentity,
                    selectionType: .playlist,
                    source: .persistedGenerated,
                    image: generated.image,
                    fileURL: generated.fileURL,
                    generationSignature: nil
                )
            }

            return nil

        case .artist(let selectionIdentity, let entry, let tracks):
            if let data = entry.artworkData,
               let image = ArtworkLoader.headerPreviewImage(data: data, maxPixelSize: 320)
            {
                let fileURL = entry.artworkFileName.map {
                    LocalLibraryPaths.artistFolderURL(for: entry.id).appendingPathComponent($0)
                }
                return ResolvedHeaderArtwork(
                    selectionIdentity: selectionIdentity,
                    selectionType: .artist,
                    source: .custom,
                    image: image,
                    fileURL: fileURL,
                    generationSignature: nil
                )
            }

            let placeholderImage = ArtistArtworkGenerator.placeholderArtwork(
                artistName: entry.displayName,
                tracks: tracks
            )
            return ResolvedHeaderArtwork(
                selectionIdentity: selectionIdentity,
                selectionType: .artist,
                source: .placeholder,
                image: placeholderImage,
                fileURL: nil,
                generationSignature: nil
            )

        case .album(let selectionIdentity, let entry, let fallbackImage):
            if let fileName = entry.artworkFileName,
               let data = entry.artworkData,
               let image = ArtworkLoader.squareHeaderPreviewImage(data: data, maxPixelSize: 320)
            {
                let fileURL = LocalLibraryPaths.albumFolderURL(for: entry.id).appendingPathComponent(fileName)
                return ResolvedHeaderArtwork(
                    selectionIdentity: selectionIdentity,
                    selectionType: .album,
                    source: .custom,
                    image: image,
                    fileURL: fileURL,
                    generationSignature: nil
                )
            }

            let fallbackPreview = entry.artworkData.flatMap {
                ArtworkLoader.squareHeaderPreviewImage(data: $0, maxPixelSize: 320)
            } ?? fallbackImage
            if let image = fallbackPreview {
                return ResolvedHeaderArtwork(
                    selectionIdentity: selectionIdentity,
                    selectionType: .album,
                    source: .albumFallback,
                    image: image,
                    fileURL: nil,
                    generationSignature: nil
                )
            }

            return ResolvedHeaderArtwork(
                selectionIdentity: selectionIdentity,
                selectionType: .album,
                source: .placeholder,
                image: nil,
                fileURL: nil,
                generationSignature: nil
            )
        }
    }

    func resolveDeferredArtwork(for request: DetailHeaderArtworkRequest) async -> ResolvedHeaderArtwork? {
        switch request {
        case .playlist(let selectionIdentity, let playlistID, let tracks):
            // If immediate resolved, use existing artwork (Rule: artwork is stable)
            if let immediate = resolveImmediately(for: request) {
                return immediate
            }

            // No artwork exists - generate for first-time initialization only
            let snapshots = tracks.map { PlaylistArtworkSnapshot(track: $0) }

            guard let image = await generator.generateArtwork(
                playlistID: playlistID,
                snapshots: snapshots
            ) else {
                logResolver("selectionType=playlist selectionIdentity=\(playlistID) source=first-generation phase=generation-failed")
                return nil
            }

            // Double-check if artwork was created while we were generating (race condition)
            let postGenerationRecord = libraryService.loadPlaylistArtworkRecord(playlistID: playlistID)
            if let custom = postGenerationRecord.customArtwork {
                return ResolvedHeaderArtwork(
                    selectionIdentity: selectionIdentity,
                    selectionType: .playlist,
                    source: .custom,
                    image: custom.image,
                    fileURL: custom.fileURL,
                    generationSignature: nil
                )
            }
            if let generated = postGenerationRecord.generatedArtwork {
                return ResolvedHeaderArtwork(
                    selectionIdentity: selectionIdentity,
                    selectionType: .playlist,
                    source: .persistedGenerated,
                    image: generated.image,
                    fileURL: generated.fileURL,
                    generationSignature: nil
                )
            }

            // Save the newly generated artwork
            let signature = PlaylistArtworkGenerator.contentSignature(tracks: tracks)
            libraryService.savePlaylistGeneratedArtwork(
                playlistID: playlistID,
                image: image,
                signature: signature
            )

            let generatedURL = LocalLibraryPaths.playlistGeneratedArtworkURL(for: playlistID)
            return ResolvedHeaderArtwork(
                selectionIdentity: selectionIdentity,
                selectionType: .playlist,
                source: .newlyGenerated,
                image: image,
                fileURL: generatedURL,
                generationSignature: nil
            )

        case .artist, .album:
            return nil
        }
    }

    private func logResolver(_ message: String) {
        print("🎨 [HeaderArtworkResolver] \(message)")
    }
}
