//
//  LocalLibraryService.swift
//  myPlayer2
//
//  kmgccc_player - Local Library Service
//  Stores audio + sidecar metadata under ~/Music/kmgccc_player Library
//

import AppKit
import Darwin
import Dispatch
import Foundation

struct TrackSidecar: Codable {
    let schemaVersion: Int
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let addedAt: Date
    let importedAt: Date?
    let lyricsTimeOffsetMs: Double?
    let originalFilePath: String?
    let audioFileName: String?
    let artworkFileName: String?
    let lyricsFileName: String?
    let lyricsType: String?
}

struct PlaylistSidecar: Codable {
    let schemaVersion: Int
    let id: UUID
    let name: String
    let createdAt: Date
    let items: [PlaylistItemSidecar]
    let legacyTrackIDs: [UUID]?

    var trackIDs: [UUID] {
        if schemaVersion >= 2 {
            return items.map(\.trackID)
        }
        return legacyTrackIDs ?? []
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case createdAt
        case items
        case trackIDs
        case trackIds
    }

    init(
        schemaVersion: Int = 2,
        id: UUID,
        name: String,
        createdAt: Date,
        items: [PlaylistItemSidecar]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.items = items
        self.legacyTrackIDs = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1

        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        schemaVersion = version

        if version >= 2 {
            items = try c.decodeIfPresent([PlaylistItemSidecar].self, forKey: .items) ?? []
            legacyTrackIDs = nil
        } else {
            let ids =
                try c.decodeIfPresent([UUID].self, forKey: .trackIDs)
                ?? c.decodeIfPresent([UUID].self, forKey: .trackIds)
                ?? []
            items = []
            legacyTrackIDs = ids
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(items, forKey: .items)
    }
}

struct PlaylistItemSidecar: Codable {
    let trackID: UUID
    let addedAt: Date
}

@MainActor
final class LocalLibraryService {

    static let shared = LocalLibraryService()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var monitors: [String: DispatchSourceFileSystemObject] = [:]
    private var monitorFDs: [String: Int32] = [:]
    private var pendingSync: DispatchWorkItem?

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Library Setup

    func ensureLibraryFolders() {
        do {
            try fileManager.createDirectory(
                at: LocalLibraryPaths.libraryRootURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: LocalLibraryPaths.tracksRootURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: LocalLibraryPaths.playlistsRootURL,
                withIntermediateDirectories: true
            )
        } catch {
            print("❌ Failed to create library folders: \(error)")
        }
    }

    // MARK: - Import

    func importAudioFile(from sourceURL: URL, trackId: UUID) throws -> String {
        ensureLibraryFolders()

        let trackFolder = LocalLibraryPaths.trackFolderURL(for: trackId)
        try fileManager.createDirectory(at: trackFolder, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeExt = ext.isEmpty ? "audio" : ext
        let audioFileName = "audio.\(safeExt)"
        let destURL = trackFolder.appendingPathComponent(audioFileName)

        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destURL)

        return "Tracks/\(trackId.uuidString)/\(audioFileName)"
    }

    // MARK: - Sidecar Write

    func writeSidecar(for track: Track) {
        guard !track.libraryRelativePath.isEmpty else { return }

        do {
            ensureLibraryFolders()
            let trackFolder = LocalLibraryPaths.trackFolderURL(for: track.id)
            try fileManager.createDirectory(at: trackFolder, withIntermediateDirectories: true)

            let audioFileName = URL(fileURLWithPath: track.libraryRelativePath).lastPathComponent

            let artworkFileName = try writeArtworkIfNeeded(track: track, folder: trackFolder)
            let lyricsInfo = try writeLyricsIfNeeded(track: track, folder: trackFolder)

            let sidecar = TrackSidecar(
                schemaVersion: 1,
                id: track.id,
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration,
                addedAt: track.addedAt,
                importedAt: track.importedAt ?? track.addedAt,
                lyricsTimeOffsetMs: track.lyricsTimeOffsetMs,
                originalFilePath: track.originalFilePath.isEmpty ? nil : track.originalFilePath,
                audioFileName: audioFileName.isEmpty ? nil : audioFileName,
                artworkFileName: artworkFileName,
                lyricsFileName: lyricsInfo.fileName,
                lyricsType: lyricsInfo.type
            )

            let data = try encoder.encode(sidecar)
            let metaURL = LocalLibraryPaths.trackMetaURL(for: track.id)
            try data.write(to: metaURL, options: .atomic)
        } catch {
            print("❌ Failed to write sidecar for \(track.title): \(error)")
        }
    }

    private func writeArtworkIfNeeded(track: Track, folder: URL) throws -> String? {
        let artworkURL = LocalLibraryPaths.trackArtworkURL(for: track.id)

        guard let data = track.artworkData, !data.isEmpty else {
            if fileManager.fileExists(atPath: artworkURL.path) {
                try fileManager.removeItem(at: artworkURL)
            }
            return nil
        }

        if let image = NSImage(data: data), let jpeg = image.jpegData(compression: 0.9) {
            try jpeg.write(to: artworkURL, options: .atomic)
        } else {
            try data.write(to: artworkURL, options: .atomic)
        }

        return artworkURL.lastPathComponent
    }

    private func writeLyricsIfNeeded(track: Track, folder: URL) throws -> (
        fileName: String?, type: String?
    ) {
        let text = preferredLyricsText(for: track)

        let existing = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let existingLyrics = (existing ?? []).filter {
            $0.lastPathComponent.lowercased().hasPrefix("lyrics.")
        }

        guard let lyrics = text else {
            for url in existingLyrics {
                try? fileManager.removeItem(at: url)
            }
            return (nil, nil)
        }

        let ext = detectLyricsExtension(for: lyrics)
        let fileName = "lyrics.\(ext)"
        let lyricsURL = folder.appendingPathComponent(fileName)

        try lyrics.write(to: lyricsURL, atomically: true, encoding: .utf8)

        for url in existingLyrics where url.lastPathComponent != fileName {
            try? fileManager.removeItem(at: url)
        }

        return (fileName, ext)
    }

    private func preferredLyricsText(for track: Track) -> String? {
        if let ttml = track.ttmlLyricText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !ttml.isEmpty
        {
            return ttml
        }

        if let text = track.lyricsText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        {
            return text
        }

        return nil
    }

    private func detectLyricsExtension(for text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("<tt") && lower.contains("</") {
            return "ttml"
        }
        if lower.contains("[") && lower.contains("]") && lower.contains(":") {
            return "lrc"
        }
        return "txt"
    }

    // MARK: - Track Deletion

    func deleteTrackFiles(_ track: Track) {
        let folder = LocalLibraryPaths.trackFolderURL(for: track.id)
        if fileManager.fileExists(atPath: folder.path) {
            do {
                try fileManager.removeItem(at: folder)
            } catch {
                print("❌ Failed to delete track folder \(folder.lastPathComponent): \(error)")
            }
        }
    }

    // MARK: - Playlist Sidecars

    func writePlaylist(_ playlist: Playlist, itemAddedAt: [UUID: Date]? = nil) {
        ensureLibraryFolders()
        let items = playlist.tracks.map { track in
            PlaylistItemSidecar(
                trackID: track.id,
                addedAt: itemAddedAt?[track.id] ?? Date()
            )
        }
        let sidecar = PlaylistSidecar(
            id: playlist.id,
            name: playlist.name,
            createdAt: playlist.createdAt,
            items: items
        )

        do {
            let data = try encoder.encode(sidecar)
            let url = LocalLibraryPaths.playlistURL(for: playlist.id)
            try data.write(to: url, options: .atomic)
        } catch {
            print("❌ Failed to write playlist sidecar '\(playlist.name)': \(error)")
        }
    }

    func writeAllPlaylists(_ playlists: [Playlist]) {
        for playlist in playlists {
            writePlaylist(playlist)
        }
    }

    func deletePlaylist(_ playlist: Playlist) {
        let url = LocalLibraryPaths.playlistURL(for: playlist.id)
        if fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                print("❌ Failed to delete playlist sidecar '\(playlist.name)': \(error)")
            }
        }
    }

    // MARK: - Bootstrap / Sync

    func bootstrapIfNeeded(repository: LibraryRepositoryProtocol) async {
        ensureLibraryFolders()

        let count = await repository.totalTrackCount()
        if count == 0 {
            let tracks = loadTracksFromDisk()
            if !tracks.isEmpty {
                await repository.addTracks(tracks)
            }

            let tracksById = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            let playlists = loadPlaylistsFromDisk(tracksById: tracksById)
            for playlist in playlists {
                await repository.addPlaylist(playlist)
            }
        } else {
            await migrateLegacyTracksIfNeeded(repository: repository)
            await refreshAvailability(repository: repository)
        }
    }

    func refreshAvailability(repository: LibraryRepositoryProtocol) async {
        // 1. Refresh Tracks Availability
        let tracks = await repository.fetchTracks(in: nil)
        for track in tracks {
            guard !track.libraryRelativePath.isEmpty else { continue }
            let url = LocalLibraryPaths.libraryURL(from: track.libraryRelativePath)
            let exists = fileManager.fileExists(atPath: url.path)

            let newAvailability: TrackAvailability = exists ? .available : .missing
            let needsImportBackfill = track.importedAt == nil

            if track.availability != newAvailability || needsImportBackfill {
                track.availability = newAvailability
                if needsImportBackfill {
                    track.importedAt = track.addedAt
                }
                await repository.updateTrack(track)
            }
        }

        // 2. Refresh Playlists from Disk
        await refreshPlaylists(repository: repository)
    }

    /// Refresh playlists by comparing raw disk sidecar data against the DB.
    /// IMPORTANT: We use PlaylistSidecar structs (not @Model Playlist objects) to avoid
    /// SwiftData implicitly inserting phantom Playlist objects into the context when
    /// managed Track objects are assigned to their relationships.
    /// IMPORTANT: We do NOT write back to disk during sync to avoid triggering
    /// the file system monitor and creating an infinite feedback loop.
    private func refreshPlaylists(repository: LibraryRepositoryProtocol) async {
        let tracks = await repository.fetchTracks(in: nil)
        let tracksById = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let diskSidecars = loadPlaylistSidecarsFromDisk()

        let dbPlaylists = await repository.fetchPlaylists()

        // 1. Identify IDs
        let diskIds = Set(diskSidecars.map { $0.id })
        let dbIds = Set(dbPlaylists.map { $0.id })

        // 2. Add New (On Disk, not in DB)
        for sidecar in diskSidecars where !dbIds.contains(sidecar.id) {
            print("📥 Found new playlist on disk: \(sidecar.name)")
            let resolvedTracks = sidecar.trackIDs.compactMap { tracksById[$0] }
            let playlist = Playlist(
                id: sidecar.id,
                name: sidecar.name,
                createdAt: sidecar.createdAt,
                tracks: resolvedTracks
            )
            await repository.addPlaylist(playlist)
        }

        // 3. Delete Stale (In DB, not on Disk)
        for playlist in dbPlaylists where !diskIds.contains(playlist.id) {
            print("🗑️ Removing stale playlist from DB: \(playlist.name)")
            await repository.deletePlaylist(playlist)
        }

        // 4. Update Existing
        // Use Set comparison to avoid false positives from SwiftData ordering differences.
        // Directly modify the managed Playlist object and save WITHOUT writing back to disk,
        // to prevent triggering the file system monitor → infinite refresh loop.
        var needsSave = false
        for sidecar in diskSidecars {
            if let dbPlaylist = dbPlaylists.first(where: { $0.id == sidecar.id }) {
                // Sync Name
                if dbPlaylist.name != sidecar.name {
                    dbPlaylist.name = sidecar.name
                    needsSave = true
                }

                // Sync Tracks — compare as Sets (order-insensitive)
                let dbTrackIdSet = Set(dbPlaylist.tracks.map { $0.id })
                let diskTrackIdSet = Set(sidecar.trackIDs)

                if dbTrackIdSet != diskTrackIdSet {
                    print("🔄 Syncing tracks for playlist: \(sidecar.name)")
                    let resolvedTracks = sidecar.trackIDs.compactMap { tracksById[$0] }
                    dbPlaylist.tracks = resolvedTracks
                    needsSave = true
                }
            }
        }

        if needsSave {
            await repository.save()
        }
    }

    /// Load raw playlist sidecar data from disk without creating @Model objects.
    /// This is safe to call during refresh because it does not touch the SwiftData context.
    func loadPlaylistSidecarsFromDisk() -> [PlaylistSidecar] {
        ensureLibraryFolders()
        var sidecars: [PlaylistSidecar] = []

        let files =
            (try? fileManager.contentsOfDirectory(
                at: LocalLibraryPaths.playlistsRootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file),
                let sidecar = try? decoder.decode(PlaylistSidecar.self, from: data)
            else {
                continue
            }
            sidecars.append(sidecar)
        }

        return sidecars
    }

    func migrateLegacyTracksIfNeeded(repository: LibraryRepositoryProtocol) async {
        let tracks = await repository.fetchTracks(in: nil)
        for track in tracks
        where track.libraryRelativePath.isEmpty && !track.fileBookmarkData.isEmpty {
            let result = track.resolveFileURL()
            guard let sourceURL = result.url else {
                track.availability = .missing
                await repository.updateTrack(track)
                continue
            }

            do {
                let relativePath = try importAudioFile(from: sourceURL, trackId: track.id)
                track.libraryRelativePath = relativePath
                if track.originalFilePath.isEmpty {
                    track.originalFilePath = sourceURL.path
                }
                track.availability = .available
                await repository.updateTrack(track)
            } catch {
                print("❌ Failed to migrate track \(track.title): \(error)")
            }

            track.stopAccessingFile(url: sourceURL)
        }
    }

    // MARK: - Disk Load

    func loadTracksFromDisk() -> [Track] {
        ensureLibraryFolders()
        var tracks: [Track] = []

        let trackDirs =
            (try? fileManager.contentsOfDirectory(
                at: LocalLibraryPaths.tracksRootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

        for dir in trackDirs where dir.hasDirectoryPath {
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                let sidecar = try? decoder.decode(TrackSidecar.self, from: data)
            else {
                continue
            }

            let audioFileName = sidecar.audioFileName ?? findAudioFileName(in: dir)
            let relativePath: String = {
                if let audioFileName {
                    return "Tracks/\(sidecar.id.uuidString)/\(audioFileName)"
                }
                return ""
            }()

            let audioURL =
                relativePath.isEmpty
                ? nil
                : LocalLibraryPaths.libraryURL(from: relativePath)
            let isAvailable = audioURL.map { fileManager.fileExists(atPath: $0.path) } ?? false

            let artworkData = sidecar.artworkFileName.flatMap { fileName -> Data? in
                let url = dir.appendingPathComponent(fileName)
                return try? Data(contentsOf: url)
            }

            var ttmlText: String?
            var lyricsText: String?
            if let lyricsFile = sidecar.lyricsFileName {
                let url = dir.appendingPathComponent(lyricsFile)
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    if lyricsFile.lowercased().hasSuffix(".ttml") {
                        ttmlText = text
                    } else {
                        lyricsText = text
                    }
                }
            }

            let track = Track(
                id: sidecar.id,
                title: sidecar.title,
                artist: sidecar.artist,
                album: sidecar.album,
                duration: sidecar.duration,
                addedAt: sidecar.addedAt,
                importedAt: sidecar.importedAt ?? sidecar.addedAt,
                lyricsTimeOffsetMs: sidecar.lyricsTimeOffsetMs ?? 0,
                fileBookmarkData: Data(),
                originalFilePath: sidecar.originalFilePath ?? "",
                libraryRelativePath: relativePath,
                availability: isAvailable ? .available : .missing,
                artworkData: artworkData,
                ttmlLyricText: ttmlText,
                lyricsText: lyricsText
            )

            tracks.append(track)
        }

        return tracks
    }

    func loadPlaylistsFromDisk(tracksById: [UUID: Track]) -> [Playlist] {
        ensureLibraryFolders()
        var playlists: [Playlist] = []

        let files =
            (try? fileManager.contentsOfDirectory(
                at: LocalLibraryPaths.playlistsRootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file),
                let sidecar = try? decoder.decode(PlaylistSidecar.self, from: data)
            else {
                continue
            }

            let tracks = sidecar.trackIDs.compactMap { tracksById[$0] }
            let playlist = Playlist(
                id: sidecar.id,
                name: sidecar.name,
                createdAt: sidecar.createdAt,
                tracks: tracks
            )
            playlists.append(playlist)
        }

        return playlists
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

    // MARK: - Monitoring (missing/removed files)

    func startMonitoring(repository: LibraryRepositoryProtocol) {
        stopMonitoring()
        ensureLibraryFolders()

        let pathsToMonitor = [
            "tracks": LocalLibraryPaths.tracksRootURL.path,
            "playlists": LocalLibraryPaths.playlistsRootURL.path,
        ]

        for (name, path) in pathsToMonitor {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else {
                print("⚠️ Failed to open \(name) path for monitoring: \(path)")
                continue
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .extend, .attrib],  // Added .extend/.attrib for better file change detection
                queue: DispatchQueue.global(qos: .utility)
            )

            source.setEventHandler { [weak self] in
                print("📝 Detected change in \(name) folder")
                self?.scheduleAvailabilitySync(repository: repository)
            }

            source.setCancelHandler { [fd] in
                close(fd)
            }

            source.resume()
            monitors[name] = source
            monitorFDs[name] = fd
            print("👀 Started monitoring \(name) at \(path)")
        }
    }

    func stopMonitoring() {
        pendingSync?.cancel()
        pendingSync = nil

        for source in monitors.values {
            source.cancel()
        }
        monitors.removeAll()

        // FDs are closed in cancel handler, but we clear our tracking
        monitorFDs.removeAll()
    }

    private func scheduleAvailabilitySync(repository: LibraryRepositoryProtocol) {
        pendingSync?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.refreshAvailability(repository: repository)
            }
        }
        pendingSync = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

extension NSImage {
    fileprivate func jpegData(compression: CGFloat) -> Data? {
        guard let tiff = tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }

        return rep.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }
}
