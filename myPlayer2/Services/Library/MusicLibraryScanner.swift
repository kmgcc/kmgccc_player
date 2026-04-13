//
//  MusicLibraryScanner.swift
//  myPlayer2
//
//  Scan authoritative Music Library sidecars with tolerant parsing.
//

import Foundation

struct ScannedTrackMeta {
    let schemaVersion: Int
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let addedAt: Date
    let importedAt: Date
    let lyricsTimeOffsetMs: Double
    let originalFilePath: String
    let audioFileName: String
    let artworkFileName: String?
    let lyricsFileName: String?
    let ttmlLyricsFileName: String?
    /// DEPRECATED: Use preferenceStats instead. Kept for migration only.
    let playCount: Int?
    /// Modern preference statistics (schemaVersion >= 3)
    let preferenceStats: TrackPreferenceStats?
    let folderURL: URL

    var libraryRelativePath: String {
        "Tracks/\(id.uuidString)/\(audioFileName)"
    }
}

@MainActor
final class MusicLibraryScanner {
    private let fileManager = FileManager.default
    private let iso8601WithFractional: ISO8601DateFormatter
    private let iso8601: ISO8601DateFormatter

    init() {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso8601WithFractional = fractional
        self.iso8601 = ISO8601DateFormatter()
    }

    func scanTracks() -> [ScannedTrackMeta] {
        let dirs =
            (try? fileManager.contentsOfDirectory(
                at: LocalLibraryPaths.tracksRootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

        var metas: [ScannedTrackMeta] = []
        for dir in dirs where dir.hasDirectoryPath {
            guard let meta = parseTrackMeta(in: dir) else { continue }
            metas.append(meta)
        }
        return metas
    }

    func scanTracks(ids: [UUID]) -> [ScannedTrackMeta] {
        ids.compactMap { id in
            parseTrackMeta(in: LocalLibraryPaths.trackFolderURL(for: id))
        }
    }

    private func parseTrackMeta(in folderURL: URL) -> ScannedTrackMeta? {
        let metaURL = folderURL.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let schemaVersion = (json["schemaVersion"] as? Int) ?? 1
        guard let idString = json["id"] as? String, let id = UUID(uuidString: idString) else {
            return nil
        }

        let title = LibraryNormalization.displayTitle(json["title"] as? String)
        let artist = LibraryNormalization.displayArtist(json["artist"] as? String)
        let album = LibraryNormalization.displayAlbum(json["album"] as? String)
        let duration = parseDouble(json["duration"]) ?? 0

        let now = Date()
        let addedAt = parseDate(json["addedAt"]) ?? parseDate(json["importedAt"]) ?? now
        let importedAt = parseDate(json["importedAt"]) ?? addedAt
        let lyricsTimeOffsetMs = parseDouble(json["lyricsTimeOffsetMs"]) ?? 0
        let originalFilePath = (json["originalFilePath"] as? String) ?? ""

        let audioFileName = (json["audioFileName"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let foundAudioFileName: String? = {
            if let audioFileName, !audioFileName.isEmpty { return audioFileName }
            return findAudioFileName(in: folderURL)
        }()

        guard let unwrappedAudioFileName = foundAudioFileName, !unwrappedAudioFileName.isEmpty
        else {
            return nil
        }

        let declaredArtworkFileName = (json["artworkFileName"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let artworkFileName = resolveArtworkFileName(
            in: folderURL,
            preferredFileName: declaredArtworkFileName
        )
        let lyricsFileName = (json["lyricsFileName"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines)

        let ttmlLyricsFileName = (json["ttmlLyricsFileName"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines)

        // Parse legacy playCount (schemaVersion < 3)
        let playCount: Int? = {
            guard let playCountValue = json["playCount"] else { return nil }
            return parseInt(playCountValue) ?? 0
        }()

        // Parse preferenceStats (schemaVersion >= 3) with tolerant field handling.
        let preferenceStats = parsePreferenceStats(json["preferenceStats"])

        return ScannedTrackMeta(
            schemaVersion: schemaVersion,
            id: id,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            addedAt: addedAt,
            importedAt: importedAt,
            lyricsTimeOffsetMs: lyricsTimeOffsetMs,
            originalFilePath: originalFilePath,
            audioFileName: unwrappedAudioFileName,
            artworkFileName: (artworkFileName?.isEmpty ?? true) ? nil : artworkFileName,
            lyricsFileName: (lyricsFileName?.isEmpty ?? true) ? nil : lyricsFileName,
            ttmlLyricsFileName: (ttmlLyricsFileName?.isEmpty ?? true) ? nil : ttmlLyricsFileName,
            playCount: playCount,  // DEPRECATED: For migration only
            preferenceStats: preferenceStats,
            folderURL: folderURL
        )
    }

    private func parseDouble(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double:
            return value.isFinite ? value : nil
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            let doubleValue = value.doubleValue
            return doubleValue.isFinite ? doubleValue : nil
        case let value as String:
            guard let parsed = Double(value), parsed.isFinite else { return nil }
            return parsed
        default:
            return nil
        }
    }

    private func parseInt(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as Double:
            guard value.isFinite else { return nil }
            return Int(value.rounded(.towardZero))
        case let value as String:
            if let parsed = Int(value) {
                return parsed
            }
            guard let parsedDouble = Double(value), parsedDouble.isFinite else { return nil }
            return Int(parsedDouble.rounded(.towardZero))
        default:
            return nil
        }
    }

    private func parseDate(_ raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        return iso8601WithFractional.date(from: value) ?? iso8601.date(from: value)
    }

    private func parsePreferenceStats(_ raw: Any?) -> TrackPreferenceStats? {
        guard let statsDict = raw as? [String: Any] else { return nil }

        var stats = TrackPreferenceStats()
        stats.playCount = max(0, parseInt(statsDict["playCount"]) ?? 0)
        stats.completePlayCount = max(0, parseInt(statsDict["completePlayCount"]) ?? 0)
        stats.skipCount = max(0, parseInt(statsDict["skipCount"]) ?? 0)
        stats.quickSkipCount = max(0, parseInt(statsDict["quickSkipCount"]) ?? 0)
        stats.totalPlayedSeconds = max(0, parseDouble(statsDict["totalPlayedSeconds"]) ?? 0)
        stats.lastPlayedAt = parseDate(statsDict["lastPlayedAt"])
        stats.lastCompletedAt = parseDate(statsDict["lastCompletedAt"])
        stats.lastSkippedAt = parseDate(statsDict["lastSkippedAt"])

        if let manualStateRaw = statsDict["manualLikeState"] as? String,
           let manualState = ManualLikeState(rawValue: manualStateRaw) {
            stats.manualLikeState = manualState
        }

        let parsedPreferenceScore = parseDouble(statsDict["preferenceScoreCache"]) ?? 0
        stats.preferenceScoreCache = parsedPreferenceScore.isFinite ? parsedPreferenceScore : 0

        let parsedEffectiveWeight = parseDouble(statsDict["effectiveWeightCache"]) ?? 1.0
        stats.effectiveWeightCache = parsedEffectiveWeight.isFinite ? parsedEffectiveWeight : 1.0

        return stats
    }

    private func findAudioFileName(in folder: URL) -> String? {
        let files =
            (try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

        if let audio = files.first(where: { $0.lastPathComponent.lowercased().hasPrefix("audio.") })
        {
            return audio.lastPathComponent
        }

        let supported = Set(Constants.FileTypes.supportedAudioExtensions)
        if let audio = files.first(where: { supported.contains($0.pathExtension.lowercased()) }) {
            return audio.lastPathComponent
        }
        return nil
    }

    private func resolveArtworkFileName(in folder: URL, preferredFileName: String?) -> String? {
        for fileName in LocalLibraryPaths.trackArtworkCandidateFileNames(preferredFileName: preferredFileName) {
            let artworkURL = folder.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: artworkURL.path) {
                return fileName
            }
        }

        if let preferredFileName, !preferredFileName.isEmpty {
            return preferredFileName
        }
        return nil
    }
}
