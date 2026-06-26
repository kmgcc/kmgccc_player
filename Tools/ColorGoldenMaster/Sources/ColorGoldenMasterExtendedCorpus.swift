import AppKit
import Foundation

struct ExtendedCorpusManifest: Codable {
    let formatVersion: Int
    let sourceRoot: String
    let randomSeed: String
    let targetCount: Int
    let generatedBy: String
    let selectionPolicy: String
    let sourceArtworkCount: Int
    let decodedArtworkCount: Int
    let candidateArtworkCount: Int
    let failedArtworkCount: Int
    let excludedGoldenGateTrackCount: Int
    let excludedUnstableRankTieCount: Int
    let selectedCount: Int
    let categoryCoverage: [ExtendedCorpusCategoryCoverage]
    let samples: [ExtendedCorpusManifestSample]
    let failures: [ExtendedCorpusManifestFailure]

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case sourceRoot = "source_root"
        case randomSeed = "random_seed"
        case targetCount = "target_count"
        case generatedBy = "generated_by"
        case selectionPolicy = "selection_policy"
        case sourceArtworkCount = "source_artwork_count"
        case decodedArtworkCount = "decoded_artwork_count"
        case candidateArtworkCount = "candidate_artwork_count"
        case failedArtworkCount = "failed_artwork_count"
        case excludedGoldenGateTrackCount = "excluded_golden_gate_track_count"
        case excludedUnstableRankTieCount = "excluded_unstable_rank_tie_count"
        case selectedCount = "selected_count"
        case categoryCoverage = "category_coverage"
        case samples
        case failures
    }
}

struct ExtendedCorpusManifestSample: Codable {
    let sampleID: String
    let trackID: String
    let artworkPath: String
    let artworkHash: String
    let source: String
    let randomSeed: String
    let title: String?
    let album: String?
    let artist: String?
    let categories: [String]
    let stats: ExtendedCorpusSampleStats

    enum CodingKeys: String, CodingKey {
        case sampleID = "sample_id"
        case trackID = "track_id"
        case artworkPath = "artwork_path"
        case artworkHash = "artwork_hash"
        case source
        case randomSeed = "random_seed"
        case title
        case album
        case artist
        case categories
        case stats
    }
}

struct ExtendedCorpusSampleStats: Codable {
    let nearMono: Bool
    let ultraDark: Bool
    let hasTrustedHue: Bool
    let avgSaturation: String
    let avgBrightness: String
    let weightedLuma: String
    let colorfulness: String
    let dominantHue: String
    let dominantHueConfidence: String
    let highSaturationAreaShare: String
    let largestHighSaturationAreaShare: String
    let displayPaletteCount: Int
    let surfacePaletteCount: Int

    enum CodingKeys: String, CodingKey {
        case nearMono = "near_mono"
        case ultraDark = "ultra_dark"
        case hasTrustedHue = "has_trusted_hue"
        case avgSaturation = "avg_saturation"
        case avgBrightness = "avg_brightness"
        case weightedLuma = "weighted_luma"
        case colorfulness
        case dominantHue = "dominant_hue"
        case dominantHueConfidence = "dominant_hue_confidence"
        case highSaturationAreaShare = "high_saturation_area_share"
        case largestHighSaturationAreaShare = "largest_high_saturation_area_share"
        case displayPaletteCount = "display_palette_count"
        case surfacePaletteCount = "surface_palette_count"
    }
}

struct ExtendedCorpusCategoryCoverage: Codable {
    let category: String
    let available: Int
    let selected: Int
    let targetMinimum: Int

    enum CodingKeys: String, CodingKey {
        case category
        case available
        case selected
        case targetMinimum = "target_minimum"
    }
}

struct ExtendedCorpusManifestFailure: Codable {
    let trackID: String
    let artworkPath: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case artworkPath = "artwork_path"
        case reason
    }
}

enum ExtendedCorpusStore {
    static let manifestURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Tools/ColorGoldenMaster/Fixtures/extended-corpus-manifest.json")

    static let categoryTargets: [(category: String, minimum: Int)] = [
        ("nearMono", 10),
        ("lowSaturation", 12),
        ("ultraDark", 10),
        ("warm", 20),
        ("cool", 20),
        ("red", 8),
        ("blue", 10),
        ("green", 6),
        ("yellow", 6),
        ("highSaturation", 15),
        ("multiColor", 12),
        ("warmPaperLowContrast", 4),
        ("blackSmallHighSat", 3),
    ]

    static func loadSamples() throws -> [GoldenSample] {
        let manifest = try loadManifest()
        return try manifest.samples.map { entry in
            guard let hash = parseHash(entry.artworkHash) else {
                throw GoldenMasterError.malformedExtendedCorpusManifest(
                    path: manifestURL.path,
                    message: "invalid artwork_hash for sample \(entry.sampleID): \(entry.artworkHash)"
                )
            }
            let categoryText = entry.categories.joined(separator: ",")
            return GoldenSample(
                id: entry.sampleID,
                title: title(for: entry),
                note: "Extended corpus frozen sample; categories=\(categoryText)",
                source: .realArtwork(
                    trackID: entry.trackID,
                    artworkPath: entry.artworkPath,
                    expectedHash: hash,
                    corpus: "extended"
                )
            )
        }
    }

    static func loadManifest() throws -> ExtendedCorpusManifest {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw GoldenMasterError.missingExtendedCorpusManifest(path: manifestURL.path)
        }
        do {
            let data = try Data(contentsOf: manifestURL)
            return try JSONDecoder().decode(ExtendedCorpusManifest.self, from: data)
        } catch let error as GoldenMasterError {
            throw error
        } catch {
            throw GoldenMasterError.malformedExtendedCorpusManifest(
                path: manifestURL.path,
                message: String(describing: error)
            )
        }
    }

    static func refresh(seed: String, targetCount requestedTarget: Int) throws -> ExtendedCorpusManifest {
        let seed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seed.isEmpty else { throw GoldenMasterError.refreshExtendedCorpusRequiresSeed }

        let scan = scanCandidates(seed: seed)
        let targetCount = min(max(requestedTarget, 100), scan.candidates.count)
        let selectedCandidates = selectCandidates(
            from: scan.candidates,
            targetCount: targetCount
        )
        let selectedIDs = Set(selectedCandidates.map(\.trackID))
        let coverage = categoryTargets.map { target in
            ExtendedCorpusCategoryCoverage(
                category: target.category,
                available: scan.candidates.filter { $0.categories.contains(target.category) }.count,
                selected: selectedCandidates.filter { $0.categories.contains(target.category) }.count,
                targetMinimum: target.minimum
            )
        }

        let samples = selectedCandidates
            .sorted { lhs, rhs in
                if lhs.trackID != rhs.trackID { return lhs.trackID < rhs.trackID }
                return lhs.artworkHash < rhs.artworkHash
            }
            .enumerated()
            .map { index, candidate in
                ExtendedCorpusManifestSample(
                    sampleID: String(
                        format: "extended.%03d-%@",
                        locale: Locale(identifier: "en_US_POSIX"),
                        index + 1,
                        String(candidate.trackID.prefix(8))
                    ),
                    trackID: candidate.trackID,
                    artworkPath: candidate.artworkPath,
                    artworkHash: candidate.artworkHash,
                    source: "local-track-library-random-plus-color-fill",
                    randomSeed: seed,
                    title: candidate.title,
                    album: candidate.album,
                    artist: candidate.artist,
                    categories: candidate.categories,
                    stats: candidate.stats
                )
            }

        let manifest = ExtendedCorpusManifest(
            formatVersion: 1,
            sourceRoot: ColorGoldenMasterSamples.trackRoot,
            randomSeed: seed,
            targetCount: targetCount,
            generatedBy: "Tools/ColorGoldenMaster/run.sh refresh-extended-corpus",
            selectionPolicy: "sorted scan; exclude Golden Gate core track IDs; analyze with ArtworkColorExtractor.analyze(from:); fixed-seed random base; deterministic color-stat quota fill; freeze selected artwork paths and FNV-1a hashes",
            sourceArtworkCount: scan.sourceArtworkCount,
            decodedArtworkCount: scan.decodedArtworkCount,
            candidateArtworkCount: scan.candidates.count,
            failedArtworkCount: scan.failures.count,
            excludedGoldenGateTrackCount: scan.excludedGoldenGateTrackCount,
            excludedUnstableRankTieCount: scan.excludedUnstableRankTieCount,
            selectedCount: selectedIDs.count,
            categoryCoverage: coverage,
            samples: samples,
            failures: scan.failures
        )
        try writeManifest(manifest)
        return manifest
    }

    static func coverageLine(from manifest: ExtendedCorpusManifest) -> String {
        manifest.categoryCoverage
            .map { "\($0.category)=\($0.selected)/\($0.available)" }
            .joined(separator: " ")
    }

    private static func title(for entry: ExtendedCorpusManifestSample) -> String {
        let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = entry.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (title?.isEmpty == false ? title : nil, artist?.isEmpty == false ? artist : nil) {
        case let (.some(title), .some(artist)):
            return "\(title) - \(artist)"
        case let (.some(title), nil):
            return title
        case (nil, .some(let artist)):
            return "Track \(entry.trackID) - \(artist)"
        case (nil, nil):
            return "Track \(entry.trackID)"
        }
    }

    private static func scanCandidates(seed: String) -> ExtendedCorpusScan {
        let rootURL = URL(fileURLWithPath: ColorGoldenMasterSamples.trackRoot, isDirectory: true)
        let goldenGateIDs = Set(ColorGoldenMasterSamples.realGoldenGate.compactMap(\.realTrackID))
        let trackURLs = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let artworkURLs = trackURLs
            .filter { url in
                ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            }
            .map { $0.appendingPathComponent("artwork.jpg") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }

        var candidates: [ExtendedCorpusCandidate] = []
        var failures: [ExtendedCorpusManifestFailure] = []
        var excludedGoldenGateTrackCount = 0
        var decodedArtworkCount = 0
        var excludedUnstableRankTieCount = 0

        for artworkURL in artworkURLs {
            let trackID = artworkURL.deletingLastPathComponent().lastPathComponent
            if goldenGateIDs.contains(trackID) {
                excludedGoldenGateTrackCount += 1
                continue
            }

            let data: Data
            do {
                data = try Data(contentsOf: artworkURL)
            } catch {
                failures.append(ExtendedCorpusManifestFailure(
                    trackID: trackID,
                    artworkPath: artworkURL.path,
                    reason: "read failed: \(error)"
                ))
                continue
            }

            guard let analysis = ArtworkColorExtractor.analyze(from: data) else {
                failures.append(ExtendedCorpusManifestFailure(
                    trackID: trackID,
                    artworkPath: artworkURL.path,
                    reason: "image decode or color analysis failed"
                ))
                continue
            }
            decodedArtworkCount += 1

            if hasUnstableRankTieRisk(analysis) {
                excludedUnstableRankTieCount += 1
                continue
            }

            let metadata = readMetadata(trackURL: artworkURL.deletingLastPathComponent())
            let categories = categories(for: analysis)
            let hash = ColorGoldenMasterSupport.f(ColorMath.fnv1a(data))
            candidates.append(ExtendedCorpusCandidate(
                trackID: trackID,
                artworkPath: artworkURL.path,
                artworkHash: hash,
                title: clean(metadata?.title),
                album: clean(metadata?.album),
                artist: clean(metadata?.artist),
                analysis: analysis,
                categories: categories,
                stats: stats(for: analysis),
                randomKey: ColorMath.fnv1a(Data("\(seed):\(trackID):\(hash)".utf8))
            ))
        }

        return ExtendedCorpusScan(
            sourceArtworkCount: artworkURLs.count,
            excludedGoldenGateTrackCount: excludedGoldenGateTrackCount,
            decodedArtworkCount: decodedArtworkCount,
            excludedUnstableRankTieCount: excludedUnstableRankTieCount,
            candidates: candidates,
            failures: failures.sorted { lhs, rhs in lhs.trackID < rhs.trackID }
        )
    }

    private static func selectCandidates(
        from candidates: [ExtendedCorpusCandidate],
        targetCount: Int
    ) -> [ExtendedCorpusCandidate] {
        let randomOrdered = candidates.sorted { lhs, rhs in
            if lhs.randomKey != rhs.randomKey { return lhs.randomKey < rhs.randomKey }
            return lhs.trackID < rhs.trackID
        }
        let baseCount = min(max(100, targetCount - 20), targetCount)
        var selected: [String: ExtendedCorpusCandidate] = [:]
        for candidate in randomOrdered.prefix(baseCount) {
            selected[candidate.trackID] = candidate
        }

        for target in categoryTargets {
            let available = candidates.filter { $0.categories.contains(target.category) }
            let desired = min(target.minimum, available.count)
            while selected.values.filter({ $0.categories.contains(target.category) }).count < desired,
                  selected.count < targetCount,
                  let next = available
                    .sorted(by: randomThenTrackID)
                    .first(where: { selected[$0.trackID] == nil })
            {
                selected[next.trackID] = next
            }
        }

        if selected.count < targetCount {
            for candidate in randomOrdered where selected[candidate.trackID] == nil {
                selected[candidate.trackID] = candidate
                if selected.count == targetCount { break }
            }
        }

        return selected.values.sorted(by: randomThenTrackID)
    }

    private static func randomThenTrackID(
        _ lhs: ExtendedCorpusCandidate,
        _ rhs: ExtendedCorpusCandidate
    ) -> Bool {
        if lhs.randomKey != rhs.randomKey { return lhs.randomKey < rhs.randomKey }
        return lhs.trackID < rhs.trackID
    }

    private static func categories(for analysis: ArtworkColorAnalysis) -> [String] {
        var categories: Set<String> = []
        if analysis.isNearMonochrome { categories.insert("nearMono") }
        if analysis.isUltraDark { categories.insert("ultraDark") }
        if analysis.avgSaturation <= 0.16 || analysis.colorfulness <= 0.10 {
            categories.insert("lowSaturation")
        }
        if analysis.avgSaturation >= 0.42
            || analysis.highSaturationAreaShare >= 0.24
            || analysis.largestHighSaturationAreaShare >= 0.12
        {
            categories.insert("highSaturation")
        }

        if let hue = trustedOKLCHHue(for: analysis) {
            for category in hueCategories(hue) {
                categories.insert(category)
            }
        }

        if distinctTrustedHueCount(analysis.displayPalette + analysis.richPalette) >= 3 {
            categories.insert("multiColor")
        }

        if isWarmPaperLowContrast(analysis) {
            categories.insert("warmPaperLowContrast")
        }

        if analysis.dominantBrightness <= 0.11
            && analysis.weightedLuma <= 0.09
            && analysis.largestHighSaturationAreaShare >= 0.002
            && analysis.largestHighSaturationAreaShare <= 0.08
            && analysis.highSaturationAreaShare <= 0.16
        {
            categories.insert("blackSmallHighSat")
        }

        if categories.isEmpty {
            categories.insert("uncategorizedColorStats")
        }
        return categories.sorted()
    }

    private static func hueCategories(_ hue: CGFloat) -> [String] {
        let h = ColorMath.normalizedHue(hue)
        var categories: [String] = []
        if h < 0.14 || h >= 0.94 {
            categories.append("red")
            categories.append("warm")
        } else if h < 0.36 {
            categories.append("yellow")
            categories.append("warm")
        } else if h < 0.52 {
            categories.append("green")
            categories.append("cool")
        } else if h < 0.78 {
            categories.append("blue")
            categories.append("cool")
        } else {
            categories.append("cool")
        }
        return categories
    }

    private static func trustedOKLCHHue(for analysis: ArtworkColorAnalysis) -> CGFloat? {
        guard let color = analysis.primaryHueSourceColor,
              let lch = OKColor.nsColorToOKLCH(color),
              lch.c >= ColorSystemTokens.NearMonochromeProfile.mutedTrustedHueChromaFloor
        else {
            return nil
        }
        return lch.h
    }

    private static func distinctTrustedHueCount(_ colors: [NSColor]) -> Int {
        var buckets: Set<Int> = []
        for color in colors {
            guard let lch = OKColor.nsColorToOKLCH(color),
                  lch.c >= ColorSystemTokens.NearMonochromeProfile.mutedTrustedHueChromaFloor
            else { continue }
            buckets.insert(Int((ColorMath.normalizedHue(lch.h) * 12).rounded(.down)))
        }
        return buckets.count
    }

    private static func isWarmPaperLowContrast(_ analysis: ArtworkColorAnalysis) -> Bool {
        guard let hue = trustedOKLCHHue(for: analysis) else { return false }
        let warm = hue < 0.36 || hue >= 0.94
        return warm
            && analysis.avgSaturation <= 0.24
            && analysis.weightedLuma >= 0.34
            && analysis.avgBrightness >= 0.42
            && analysis.lightnessVariance <= 0.045
    }

    private static func stats(for analysis: ArtworkColorAnalysis) -> ExtendedCorpusSampleStats {
        ExtendedCorpusSampleStats(
            nearMono: analysis.isNearMonochrome,
            ultraDark: analysis.isUltraDark,
            hasTrustedHue: analysis.hasTrustedHueCandidate,
            avgSaturation: ColorGoldenMasterSupport.f(analysis.avgSaturation),
            avgBrightness: ColorGoldenMasterSupport.f(analysis.avgBrightness),
            weightedLuma: ColorGoldenMasterSupport.f(analysis.weightedLuma),
            colorfulness: ColorGoldenMasterSupport.f(analysis.colorfulness),
            dominantHue: ColorGoldenMasterSupport.f(analysis.dominantHue),
            dominantHueConfidence: ColorGoldenMasterSupport.f(analysis.dominantHueConfidence),
            highSaturationAreaShare: ColorGoldenMasterSupport.f(analysis.highSaturationAreaShare),
            largestHighSaturationAreaShare: ColorGoldenMasterSupport.f(
                analysis.largestHighSaturationAreaShare
            ),
            displayPaletteCount: analysis.displayPalette.count,
            surfacePaletteCount: analysis.surfacePalette.count
        )
    }

    private static func hasUnstableRankTieRisk(_ analysis: ArtworkColorAnalysis) -> Bool {
        hasShareTieRisk(
            colors: analysis.surfacePalette,
            shares: analysis.surfacePaletteAreaShares
        ) || hasShareTieRisk(
            colors: analysis.salientHighlightPalette,
            shares: analysis.salientHighlightAreaShares
        )
    }

    private static func hasShareTieRisk(colors: [NSColor], shares: [CGFloat]) -> Bool {
        guard colors.count > 1, shares.count > 1 else { return false }
        let count = min(colors.count, shares.count)
        if count >= 8,
           let tailShare = shares.prefix(count).last,
           tailShare <= 0.027
        {
            return true
        }
        for left in 0..<count {
            for right in (left + 1)..<count {
                guard abs(shares[left] - shares[right]) <= 0.000_000_5,
                      rgbDistance(colors[left], colors[right]) >= 0.035
                else { continue }
                return true
            }
        }
        return false
    }

    private static func rgbDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let left = lhs.usingColorSpace(.deviceRGB) ?? lhs
        let right = rhs.usingColorSpace(.deviceRGB) ?? rhs
        let dr = left.redComponent - right.redComponent
        let dg = left.greenComponent - right.greenComponent
        let db = left.blueComponent - right.blueComponent
        return sqrt(dr * dr + dg * dg + db * db)
    }

    private static func readMetadata(trackURL: URL) -> TrackMetadata? {
        let url = trackURL.appendingPathComponent("meta.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(TrackMetadata.self, from: data)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func parseHash(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt64(trimmed.dropFirst(2), radix: 16)
        }
        return UInt64(trimmed, radix: 16)
    }

    private static func writeManifest(_ manifest: ExtendedCorpusManifest) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(manifest)
            data.append(0x0A)
            try FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: manifestURL, options: [.atomic])
        } catch {
            throw GoldenMasterError.writeFailed(
                path: manifestURL.path,
                message: String(describing: error)
            )
        }
    }
}

private struct ExtendedCorpusScan {
    let sourceArtworkCount: Int
    let excludedGoldenGateTrackCount: Int
    let decodedArtworkCount: Int
    let excludedUnstableRankTieCount: Int
    let candidates: [ExtendedCorpusCandidate]
    let failures: [ExtendedCorpusManifestFailure]
}

private struct ExtendedCorpusCandidate {
    let trackID: String
    let artworkPath: String
    let artworkHash: String
    let title: String?
    let album: String?
    let artist: String?
    let analysis: ArtworkColorAnalysis
    let categories: [String]
    let stats: ExtendedCorpusSampleStats
    let randomKey: UInt64
}

private struct TrackMetadata: Decodable {
    let id: String?
    let title: String?
    let album: String?
    let artist: String?
}

private extension GoldenSample {
    var realTrackID: String? {
        switch source {
        case let .realTrack(trackID):
            return trackID
        case let .realArtwork(trackID, _, _, _):
            return trackID
        case .synthetic:
            return nil
        }
    }
}
