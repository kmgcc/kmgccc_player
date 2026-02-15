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

        let artworkFileName = (json["artworkFileName"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let lyricsFileName = (json["lyricsFileName"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines)

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
            folderURL: folderURL
        )
    }

    private func parseDouble(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private func parseDate(_ raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        return iso8601WithFractional.date(from: value) ?? iso8601.date(from: value)
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
}
