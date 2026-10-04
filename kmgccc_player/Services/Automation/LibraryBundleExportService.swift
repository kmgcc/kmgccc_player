import CryptoKit
import Foundation
import PlayerAutomationProtocol

nonisolated struct LibraryBundleExportTrackInput: Sendable {
    let metadata: AutomationMetadataDocumentTrack
    let audioURL: URL?
    let artworkURL: URL?
    let lyricsURL: URL?
    let ttmlURL: URL?
    let failures: [String]
}

nonisolated struct LibraryBundleExportPlaylistInput: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let description: String
    let trackIDs: [UUID]
}

nonisolated struct LibraryBundleExportOutcome: Sendable {
    let outputDirectory: URL
    let trackCount: Int
    let playlistCount: Int
    let copiedFileCount: Int
    let copiedBytes: Int64
    let failures: [String]
}

private nonisolated struct LibraryBundleExportFile: Codable, Sendable {
    let trackID: UUID?
    let kind: String
    let relativePath: String
    let byteCount: Int64
    let sha256: String
}

private nonisolated struct LibraryBundleExportTrack: Codable, Sendable {
    let id: UUID
    let audioPath: String?
    let artworkPath: String?
    let lyricsPath: String?
    let ttmlPath: String?
}

private nonisolated struct LibraryBundleExportManifest: Codable, Sendable {
    let schemaVersion: Int
    let libraryID: UUID
    let mode: String
    let exportedAt: Date
    let revision: String
    let trackCount: Int
    let playlistCount: Int
    let metadataPages: [String]
    let tracks: [LibraryBundleExportTrack]
    let files: [LibraryBundleExportFile]
    let failures: [String]
}

nonisolated enum LibraryBundleExportService {
    private struct Asset: Sendable {
        let trackID: UUID
        let kind: String
        let sourceURL: URL
        let relativePath: String
    }

    private struct CopyResult: Sendable {
        let record: LibraryBundleExportFile
    }

    static func estimatedBytes(for tracks: [LibraryBundleExportTrackInput]) -> Int64 {
        tracks
            .flatMap { [$0.audioURL, $0.artworkURL, $0.lyricsURL, $0.ttmlURL] }
            .compactMap { $0 }
            .reduce(Int64(0)) { total, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                return total + max(0, size)
            }
    }

    static func export(
        libraryID: UUID,
        mode: String,
        revision: String,
        destinationDirectory: URL,
        tracks: [LibraryBundleExportTrackInput],
        playlists: [LibraryBundleExportPlaylistInput],
        progress: @escaping @MainActor @Sendable (Int, Int, String) -> Void
    ) async throws -> LibraryBundleExportOutcome {
        let fileManager = FileManager.default
        let date = Date()
        let stamp = ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let baseName = "PlayerLibrary-\(libraryID.uuidString)-\(stamp)"
        let finalURL = uniqueDirectoryURL(named: baseName, in: destinationDirectory)
        let stagingURL = destinationDirectory.appendingPathComponent(
            ".\(baseName)-\(UUID().uuidString).partial",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        do {
            for directory in ["Media", "Artwork", "Lyrics", "Metadata"] {
                try fileManager.createDirectory(
                    at: stagingURL.appendingPathComponent(directory, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }

            var failures = tracks.flatMap(\.failures)
            var trackRecords = tracks.map {
                LibraryBundleExportTrack(id: $0.metadata.id, audioPath: nil, artworkPath: nil, lyricsPath: nil, ttmlPath: nil)
            }
            var files: [LibraryBundleExportFile] = []
            let assets = makeAssets(from: tracks)
            let metadataPages = max(1, (tracks.count + 99) / 100)
            let totalSteps = assets.count + metadataPages + 2
            var completedSteps = 0

            for asset in assets {
                try Task.checkCancellation()
                let destination = stagingURL.appendingPathComponent(asset.relativePath)
                do {
                    let copied = try await copyAndHash(asset, to: destination)
                    files.append(copied.record)
                    if let index = trackRecords.firstIndex(where: { $0.id == asset.trackID }) {
                        let current = trackRecords[index]
                        trackRecords[index] = LibraryBundleExportTrack(
                            id: current.id,
                            audioPath: asset.kind == "audio" ? asset.relativePath : current.audioPath,
                            artworkPath: asset.kind == "artwork" ? asset.relativePath : current.artworkPath,
                            lyricsPath: asset.kind == "lyrics" ? asset.relativePath : current.lyricsPath,
                            ttmlPath: asset.kind == "ttml" ? asset.relativePath : current.ttmlPath
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    failures.append("\(asset.trackID.uuidString): \(asset.kind) could not be copied")
                }
                completedSteps += 1
                await progress(completedSteps, totalSteps, "copying \(asset.kind)")
            }

            let exportedAt = date
            for pageIndex in 0..<metadataPages {
                try Task.checkCancellation()
                let offset = pageIndex * 100
                let pageTracks = Array(tracks.dropFirst(offset).prefix(100)).map(\.metadata)
                let nextOffset = offset + pageTracks.count < tracks.count ? offset + pageTracks.count : nil
                let page = AutomationMetadataDocument(
                    sourceLibraryID: libraryID,
                    exportedAt: exportedAt,
                    revision: revision,
                    offset: offset,
                    limit: 100,
                    total: tracks.count,
                    nextOffset: nextOffset,
                    tracks: pageTracks
                )
                let relativePath = "Metadata/tracks-\(String(format: "%05d", offset)).json"
                files.append(try writeJSON(page, kind: "metadata", relativePath: relativePath, to: stagingURL))
                completedSteps += 1
                await progress(completedSteps, totalSteps, "writing metadata")
            }

            try Task.checkCancellation()
            files.append(try writeJSON(
                playlists,
                kind: "playlists",
                relativePath: "Metadata/playlists.json",
                to: stagingURL
            ))
            completedSteps += 1
            await progress(completedSteps, totalSteps, "writing playlists")

            let manifest = LibraryBundleExportManifest(
                schemaVersion: 1,
                libraryID: libraryID,
                mode: mode,
                exportedAt: exportedAt,
                revision: revision,
                trackCount: tracks.count,
                playlistCount: playlists.count,
                metadataPages: (0..<metadataPages).map {
                    "Metadata/tracks-\(String(format: "%05d", $0 * 100)).json"
                },
                tracks: trackRecords.sorted { $0.id.uuidString < $1.id.uuidString },
                files: files.sorted { $0.relativePath < $1.relativePath },
                failures: failures
            )
            files.append(try writeJSON(
                manifest,
                kind: "manifest",
                relativePath: "manifest.json",
                to: stagingURL
            ))
            completedSteps += 1
            await progress(completedSteps, totalSteps, "finalizing package")
            try Task.checkCancellation()
            try fileManager.moveItem(at: stagingURL, to: finalURL)
            return LibraryBundleExportOutcome(
                outputDirectory: finalURL,
                trackCount: tracks.count,
                playlistCount: playlists.count,
                copiedFileCount: files.count,
                copiedBytes: files.reduce(0) { $0 + $1.byteCount },
                failures: failures
            )
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    private static func makeAssets(from tracks: [LibraryBundleExportTrackInput]) -> [Asset] {
        tracks.flatMap { track -> [Asset] in
            [
                track.audioURL.map { Asset(trackID: track.metadata.id, kind: "audio", sourceURL: $0, relativePath: "Media/\(track.metadata.id.uuidString)/audio.\(safeExtension($0))") },
                track.artworkURL.map { Asset(trackID: track.metadata.id, kind: "artwork", sourceURL: $0, relativePath: "Artwork/\(track.metadata.id.uuidString).\(safeExtension($0))") },
                track.lyricsURL.map { Asset(trackID: track.metadata.id, kind: "lyrics", sourceURL: $0, relativePath: "Lyrics/\(track.metadata.id.uuidString).\(safeExtension($0))") },
                track.ttmlURL.map { Asset(trackID: track.metadata.id, kind: "ttml", sourceURL: $0, relativePath: "Lyrics/\(track.metadata.id.uuidString).ttml") }
            ].compactMap { $0 }
        }.sorted {
            if $0.trackID != $1.trackID { return $0.trackID.uuidString < $1.trackID.uuidString }
            return $0.kind < $1.kind
        }
    }

    private static func copyAndHash(_ asset: Asset, to destination: URL) async throws -> CopyResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.isReadableFile(atPath: asset.sourceURL.path),
              let source = FileHandle(forReadingAtPath: asset.sourceURL.path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil),
              let output = FileHandle(forWritingAtPath: destination.path) else {
            try? source.close()
            throw CocoaError(.fileWriteNoPermission)
        }
        defer {
            try? source.close()
            try? output.close()
        }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            hasher.update(data: chunk)
            byteCount += Int64(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return CopyResult(record: LibraryBundleExportFile(
            trackID: asset.trackID,
            kind: asset.kind,
            relativePath: asset.relativePath,
            byteCount: byteCount,
            sha256: digest
        ))
    }

    private static func writeJSON<Value: Encodable & Sendable>(
        _ value: Value,
        kind: String,
        relativePath: String,
        to root: URL
    ) throws -> LibraryBundleExportFile {
        let data = try AutomationWireCoding.encoder().encode(value)
        let destination = root.appendingPathComponent(relativePath)
        try data.write(to: destination, options: .atomic)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return LibraryBundleExportFile(
            trackID: nil,
            kind: kind,
            relativePath: relativePath,
            byteCount: Int64(data.count),
            sha256: digest
        )
    }

    private static func uniqueDirectoryURL(named name: String, in parent: URL) -> URL {
        var candidate = parent.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(name)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func safeExtension(_ url: URL) -> String {
        let value = url.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return value.isEmpty ? "bin" : value
    }
}
