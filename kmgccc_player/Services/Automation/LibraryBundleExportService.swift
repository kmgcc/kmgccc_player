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
    var motionArtwork: TrackMotionArtwork? = nil
    var libraryRootURL: URL? = nil
    var mediaSelection: AudioMediaSelection? = nil
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
    var motionArtwork: TrackMotionArtwork? = nil
    var mediaSelection: AudioMediaSelection? = nil
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
        var relativePath: String
        var motionDescriptor: StoredMotionArtwork? = nil
    }

    private struct CopyResult: Sendable {
        let record: LibraryBundleExportFile
    }

    static func estimatedBytes(for tracks: [LibraryBundleExportTrackInput]) -> Int64 {
        var counted = Set<String>()
        return makeAssets(from: tracks)
            .reduce(Int64(0)) { total, asset in
                guard counted.insert(asset.relativePath).inserted else { return total }
                let size = (try? asset.sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
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
            for directory in ["Media", "Artwork", "Lyrics", "Metadata", "Tracks"] {
                try fileManager.createDirectory(
                    at: stagingURL.appendingPathComponent(directory, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }

            var failures = tracks.flatMap(\.failures)
            var trackRecords = tracks.map {
                LibraryBundleExportTrack(id: $0.metadata.id, audioPath: nil, artworkPath: nil, lyricsPath: nil, ttmlPath: nil,
                    mediaSelection: exportSelection($0.mediaSelection))
            }
            var files: [LibraryBundleExportFile] = []
            var copiedAssets: [String: CopyResult] = [:]
            let assets = makeAssets(from: tracks)
            let metadataPages = max(1, (tracks.count + 99) / 100)
            let totalSteps = assets.count + metadataPages + 2
            var completedSteps = 0

            for asset in assets {
                try Task.checkCancellation()
                let destination = stagingURL.appendingPathComponent(asset.relativePath)
                do {
                    if copiedAssets[asset.relativePath] == nil {
                        let copied = try await copyAndHash(asset, to: destination)
                        copiedAssets[asset.relativePath] = copied
                        files.append(copied.record)
                    }
                    if let index = trackRecords.firstIndex(where: { $0.id == asset.trackID }) {
                        let current = trackRecords[index]
                        var motion = current.motionArtwork
                        if var descriptor = asset.motionDescriptor,
                           let original = tracks.first(where: { $0.metadata.id == asset.trackID })?.motionArtwork {
                            if motion == nil {
                                motion = original
                                motion?.assets = []
                            }
                            descriptor.relativePath = asset.relativePath
                            motion?.assets.append(descriptor)
                        }
                        trackRecords[index] = LibraryBundleExportTrack(
                            id: current.id,
                            audioPath: asset.kind == "audio" ? asset.relativePath : current.audioPath,
                            artworkPath: asset.kind == "artwork" ? asset.relativePath : current.artworkPath,
                            lyricsPath: asset.kind == "lyrics" ? asset.relativePath : current.lyricsPath,
                            ttmlPath: asset.kind == "ttml" ? asset.relativePath : current.ttmlPath,
                            motionArtwork: motion,
                            mediaSelection: current.mediaSelection
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

            files.append(contentsOf: try writeCueDescriptors(tracks: tracks, records: trackRecords, to: stagingURL))
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
                schemaVersion: tracks.contains(where: { $0.mediaSelection != nil }) ? 2 : 1,
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

    private static func exportSelection(_ source: AudioMediaSelection?) -> AudioMediaSelection? {
        guard var selection = source else { return nil }
        selection.descriptorPath = nil
        selection.descriptorFingerprint = nil
        return selection
    }

    private static func audioExportPath(track: LibraryBundleExportTrackInput, url: URL) -> String {
        if track.mediaSelection != nil {
            return "Media/Shared/\(AudioMediaSelection.groupID(for: url).uuidString)/audio.\(safeExtension(url))"
        }
        return "Media/\(track.metadata.id.uuidString)/audio.\(safeExtension(url))"
    }

    private static func artworkExportPath(track: LibraryBundleExportTrackInput, url: URL) -> String {
        if track.mediaSelection != nil {
            let identity = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
            return "Artwork/Shared/\(identity).\(safeExtension(url))"
        }
        return "Artwork/\(track.metadata.id.uuidString).\(safeExtension(url))"
    }

    private static func writeCueDescriptors(tracks: [LibraryBundleExportTrackInput],
        records: [LibraryBundleExportTrack], to root: URL) throws -> [LibraryBundleExportFile] {
        let groups = Dictionary(grouping: tracks.filter { $0.mediaSelection?.kind == .cue },
            by: { $0.mediaSelection!.groupID })
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var files: [LibraryBundleExportFile] = []
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") + "\""
        }
        for (groupID, members) in groups {
            let sorted = members.sorted { $0.mediaSelection!.trackNumber < $1.mediaSelection!.trackNumber }
            guard let first = sorted.first, sorted.allSatisfy({ track in
                guard let selection = track.mediaSelection, selection.timeScale > 0,
                      selection.trackNumber <= 99, byID[track.metadata.id]?.audioPath != nil else { return false }
                let cueFrame = selection.startSeconds * 75
                return cueFrame.isFinite && abs(cueFrame - cueFrame.rounded()) < 0.000_001 && cueFrame < Double(Int64.max)
            }) else { continue }
            let physicalFiles = Dictionary(grouping: sorted, by: { byID[$0.metadata.id]?.audioPath ?? "" })
            let completeRanges = physicalFiles.values.allSatisfy { members in
                let ranges = members.sorted { $0.mediaSelection!.start < $1.mediaSelection!.start }
                guard let last = ranges.last, let url = last.audioURL,
                      let resource = try? AudioDecoderFactory.open(url),
                      let selection = last.mediaSelection else { return false }
                let end = ((selection.startSeconds + selection.duration) * resource.sampleRate).rounded(.down)
                guard abs(end - Double(resource.length)) <= 1 else { return false }
                return zip(ranges, ranges.dropFirst()).allSatisfy { previous, next in
                    let prior = previous.mediaSelection!
                    return abs(prior.startSeconds + prior.duration - next.mediaSelection!.startSeconds) < 0.000_001
                }
            }
            guard completeRanges else { continue }
            var text = "TITLE \(quoted(first.metadata.album))\nPERFORMER \(quoted(first.mediaSelection?.albumArtist ?? first.metadata.artist))\n"
            var previousFile: String?
            for track in sorted {
                guard let selection = track.mediaSelection, let audioPath = byID[track.metadata.id]?.audioPath else { continue }
                if audioPath != previousFile {
                    let type = URL(fileURLWithPath: audioPath).pathExtension.lowercased() == "mp3" ? "MP3" : "WAVE"
                    text += "FILE \(quoted("../" + String(audioPath.dropFirst("Media/".count)))) \(type)\n"
                    previousFile = audioPath
                }
                let frame = Int64((selection.startSeconds * 75).rounded())
                text += String(format: "  TRACK %02d AUDIO\n", selection.trackNumber)
                text += "    TITLE \(quoted(track.metadata.title))\n    PERFORMER \(quoted(track.metadata.artist))\n"
                text += String(format: "    INDEX 01 %02lld:%02lld:%02lld\n", frame / 4500, frame / 75 % 60, frame % 75)
            }
            let relativePath = "Media/Programs/\(groupID.uuidString).cue"
            let destination = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(text.utf8)
            try data.write(to: destination, options: .atomic)
            files.append(LibraryBundleExportFile(trackID: nil, kind: "cue", relativePath: relativePath,
                byteCount: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        }
        return files
    }

    private static func makeAssets(from tracks: [LibraryBundleExportTrackInput]) -> [Asset] {
        let assets = tracks.flatMap { track -> [Asset] in
            var assets = [
                track.audioURL.map { Asset(trackID: track.metadata.id, kind: "audio", sourceURL: $0, relativePath: audioExportPath(track: track, url: $0)) },
                track.artworkURL.map { Asset(trackID: track.metadata.id, kind: "artwork", sourceURL: $0, relativePath: artworkExportPath(track: track, url: $0)) },
                track.lyricsURL.map { Asset(trackID: track.metadata.id, kind: "lyrics", sourceURL: $0, relativePath: "Lyrics/\(track.metadata.id.uuidString).\(safeExtension($0))") },
                track.ttmlURL.map { Asset(trackID: track.metadata.id, kind: "ttml", sourceURL: $0, relativePath: "Lyrics/\(track.metadata.id.uuidString).ttml") }
            ].compactMap { $0 }
            if let audio = track.audioURL, audio.pathExtension.lowercased() == "wv" {
                let correction = audio.deletingPathExtension().appendingPathExtension("wvc")
                if FileManager.default.isReadableFile(atPath: correction.path) {
                    let relative = (audioExportPath(track: track, url: audio) as NSString).deletingPathExtension + ".wvc"
                    assets.append(Asset(trackID: track.metadata.id, kind: "correction", sourceURL: correction, relativePath: relative))
                }
            }
            if let motion = track.motionArtwork, let root = track.libraryRootURL {
                let folder = root.appendingPathComponent("Tracks/\(track.metadata.id.uuidString)", isDirectory: true).standardizedFileURL
                for descriptor in motion.assets {
                    guard !descriptor.relativePath.hasPrefix("/"),
                          !descriptor.relativePath.split(separator: "/").contains("..") else { continue }
                    let isTrackAsset = descriptor.relativePath.hasPrefix("Tracks/")
                    let isLibraryRelative = isTrackAsset || descriptor.relativePath.hasPrefix("Enrichment/")
                    let base = isLibraryRelative ? root : root.appendingPathComponent("Enrichment", isDirectory: true)
                    let source = base.appendingPathComponent(descriptor.relativePath).standardizedFileURL
                    let sharedFolder = root.appendingPathComponent("Enrichment/AlbumAssets", isDirectory: true).standardizedFileURL
                    let validTrack = source.deletingLastPathComponent().path == folder.path
                    let validAlbum = !isTrackAsset && source.path.hasPrefix(sharedFolder.path + "/")
                    guard validTrack || validAlbum,
                          source.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { continue }
                    assets.append(Asset(
                        trackID: track.metadata.id, kind: "motion.\(descriptor.kind)", sourceURL: source,
                        relativePath: isLibraryRelative ? descriptor.relativePath : "Enrichment/\(descriptor.relativePath)",
                        motionDescriptor: descriptor
                    ))
                }
            }
            return assets
        }.sorted {
            if $0.trackID != $1.trackID { return $0.trackID.uuidString < $1.trackID.uuidString }
            return $0.kind < $1.kind
        }
        var pathsBySource: [String: String] = [:]
        return assets.map { asset in
            guard ["audio", "artwork", "correction"].contains(asset.kind) else { return asset }
            let key = "\(asset.kind)|\(asset.sourceURL.resolvingSymlinksInPath().standardizedFileURL.path)"
            var shared = asset
            shared.relativePath = pathsBySource[key] ?? asset.relativePath
            pathsBySource[key] = shared.relativePath
            return shared
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
