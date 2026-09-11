import Foundation
import NativeLyrics

/// The Demo passes the library's original AMLL TTML directly to the native
/// decoder. The original bytes remain available for the renderer while the
/// parsed document supplies catalog metadata and preview setup.
struct DemoTTMLImportResult: Sendable {
    let data: Data
    let document: LyricsDocument
}

enum DemoTTMLImporter {
    static func load(_ data: Data) throws -> DemoTTMLImportResult {
        DemoTTMLImportResult(data: data, document: try TTMLDecoder().decode(data))
    }

    static func metadataTitle(_ data: Data) -> String? {
        guard let document = try? TTMLDecoder().decode(data) else { return nil }
        return document.metadata["musicName"]?.first
            ?? (document.title == "TTML Lyrics" ? nil : document.title)
    }
}

struct DemoLibrarySong: Sendable, Equatable {
    let title: String
    let subtitle: String
    let lyricURL: URL
    let audioURL: URL?
    let rootLabel: String
}

enum DemoLibraryCatalog {
    private static let maxSongs = 48

    static func discover() -> [DemoLibrarySong] {
        let registered = registeredRoots()
        let roots = registered.isEmpty
            ? [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")]
            : registered
        var lyricURLs = Set<URL>()
        for root in roots {
            let tracks = root.appendingPathComponent("Tracks", isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: tracks,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                let lyric = entry.appendingPathComponent("lyrics.ttml")
                guard FileManager.default.fileExists(atPath: lyric.path) else { continue }
                lyricURLs.insert(lyric.standardizedFileURL)
            }
        }

        // A registry can be stale during a first launch. Only then fall back
        // to a bounded directory walk instead of traversing every file under
        // ~/Music on every Demo launch.
        if lyricURLs.isEmpty, !registered.isEmpty {
            let music = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
            if let enumerator = FileManager.default.enumerator(
                at: music,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let url as URL in enumerator {
                    guard url.lastPathComponent == "Tracks" else { continue }
                    for entry in (try? FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? [] {
                        let lyric = entry.appendingPathComponent("lyrics.ttml")
                        if FileManager.default.fileExists(atPath: lyric.path) {
                            lyricURLs.insert(lyric.standardizedFileURL)
                        }
                    }
                }
            }
        }

        let songs = lyricURLs.compactMap(makeSong)
        return songs.sorted {
            let left = $0.title.localizedStandardCompare($1.title)
            if left == .orderedSame { return $0.lyricURL.path < $1.lyricURL.path }
            return left == .orderedAscending
        }.prefix(maxSongs).map { $0 }
    }

    private static func registeredRoots() -> [URL] {
        let registryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kmgccc.player/LibraryRegistry.json")
        guard let data = try? Data(contentsOf: registryURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let libraries = object["libraries"] as? [[String: Any]] else { return [] }
        return libraries.compactMap { item in
            guard let path = item["lastKnownPath"] as? String, !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
    }

    private static func makeSong(url: URL) -> DemoLibrarySong? {
        guard let data = try? Data(contentsOf: url),
              let imported = try? DemoTTMLImporter.load(data) else { return nil }
        let meta = readMetadata(at: url.deletingLastPathComponent().appendingPathComponent("meta.json"))
        let documentTitle = imported.document.title == "TTML Lyrics" ? nil : imported.document.title
        let title = meta.title ?? documentTitle ?? url.deletingLastPathComponent().lastPathComponent
        let subtitle = [meta.artist, meta.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let directory = url.deletingLastPathComponent()
        let audio = ["audio.m4a", "audio.mp3", "audio.flac", "audio.wav"]
            .map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        return DemoLibrarySong(title: title, subtitle: subtitle, lyricURL: url, audioURL: audio, rootLabel: rootName(for: url))
    }

    private struct Meta {
        var title: String?
        var artist: String?
        var album: String?
    }

    private static func readMetadata(at url: URL) -> Meta {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Meta() }
        func string(_ key: String) -> String? {
            guard let value = object[key] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        return Meta(title: string("title"), artist: string("artist"), album: string("album"))
    }

    private static func rootName(for url: URL) -> String {
        let components = url.pathComponents
        if let index = components.lastIndex(where: { $0.hasSuffix("kmgccc_player Library") }), index > 0 {
            return components[index].replacingOccurrences(of: "kmgccc_player Library", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Library"
                : components[index]
        }
        return "Music"
    }
}
