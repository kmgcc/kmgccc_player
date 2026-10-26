//
//  LibraryPaths.swift
//  kmgccc_player
//
//  Immutable paths rooted in one music library.
//

import Foundation

nonisolated struct LibraryPaths: Sendable, Equatable {
    static let rootDirectoryName = "kmgccc_player Library"
    static let preferredTrackArtworkFileName = "artwork.jpg"
    static let legacyTrackArtworkFileName = "artwork.png"

    /// Naming applies only when creating a library. Existing roots keep their
    /// captured path, independently of their manifest's display name.
    static func newLibraryDirectoryName(for displayName: String) -> String {
        let separators = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let sanitizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: separators)
            .joined(separator: "-")
        // Leave room for the fixed prefix and collision suffix, including for
        // names whose characters occupy multiple UTF-8 bytes.
        var nameComponent = ""
        for character in sanitizedName {
            guard nameComponent.utf8.count + String(character).utf8.count <= 180 else { break }
            nameComponent.append(character)
        }
        return "\(rootDirectoryName) - \(nameComponent)"
    }

    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    var manifestURL: URL { rootURL.appendingPathComponent(MusicLibraryManifest.fileName) }

    var settingsRootURL: URL { directory("Settings") }
    var librarySettingsURL: URL { settingsRootURL.appendingPathComponent("library-settings.json") }
    var libraryOrderingURL: URL { settingsRootURL.appendingPathComponent("ordering.json") }
    /// Durable observation state for App-owned automation Jobs. This is not a
    /// second source of library truth; it only stores Job progress/history and
    /// the narrow retry payload needed by supported automation operations.
    var automationJobsURL: URL { settingsRootURL.appendingPathComponent("automation-jobs.json") }
    var writerLockURL: URL { settingsRootURL.appendingPathComponent(".writer.lock") }

    var transactionsRootURL: URL { directory("Transactions") }
    var pendingTransactionsRootURL: URL {
        transactionsRootURL.appendingPathComponent("Pending", isDirectory: true)
    }
    var completedTransactionsRootURL: URL {
        transactionsRootURL.appendingPathComponent("Completed", isDirectory: true)
    }

    var tracksRootURL: URL { directory("Tracks") }
    var sourcesRootURL: URL { directory("Sources") }
    var playlistsRootURL: URL { directory("Playlists") }
    var artistsRootURL: URL { directory("Artists") }
    var albumsRootURL: URL { directory("Albums") }

    /// Persisted provider snapshots and original media, retained with the library.
    var musicEnrichmentRootURL: URL { directory("Enrichment") }

    var playbackHistoryRootURL: URL { directory("PlaybackHistory") }
    var playbackHistoryStoreURL: URL {
        playbackHistoryRootURL.appendingPathComponent("PlaybackHistory.sqlite")
    }

    var indexRootURL: URL { directory("Index") }
    var trackIndexStoreURL: URL { indexRootURL.appendingPathComponent("TrackIndex.sqlite") }
    var searchIndexStoreURL: URL { indexRootURL.appendingPathComponent("LibrarySearch.sqlite") }

    var cacheRootURL: URL { directory("Cache") }
    var artworkCacheRootURL: URL { cacheRootURL.appendingPathComponent("Artwork", isDirectory: true) }
    var lyricsCacheRootURL: URL { cacheRootURL.appendingPathComponent("Lyrics", isDirectory: true) }
    var colorsCacheRootURL: URL { cacheRootURL.appendingPathComponent("Colors", isDirectory: true) }
    var homeCacheRootURL: URL { cacheRootURL.appendingPathComponent("Home", isDirectory: true) }
    var externalPlaybackCacheRootURL: URL {
        cacheRootURL.appendingPathComponent("ExternalPlayback", isDirectory: true)
    }
    var importStagingRootURL: URL {
        cacheRootURL.appendingPathComponent("ImportStaging", isDirectory: true)
    }
    var libraryScanCacheRootURL: URL {
        cacheRootURL.appendingPathComponent("LibraryScan", isDirectory: true)
    }
    var libraryScanManifestURL: URL {
        libraryScanCacheRootURL.appendingPathComponent("manifest.json")
    }
    var sourceScanCacheRootURL: URL {
        cacheRootURL.appendingPathComponent("SourceScan", isDirectory: true)
    }
    var loudnessCacheRootURL: URL {
        cacheRootURL.appendingPathComponent("Loudness", isDirectory: true)
    }

    /// Files earlier versions left in the library that nothing reads any
    /// more: the referenced-library migration backup and its journal, the
    /// pre-registry upgrade journal and the root-level scan manifest.
    var retiredDataURLs: [URL] {
        [
            settingsRootURL.appendingPathComponent("DomainMigrationBackups", isDirectory: true),
            settingsRootURL.appendingPathComponent("domain-migration.json"),
            settingsRootURL.appendingPathComponent("library-upgrade.json"),
            rootURL.appendingPathComponent(".kmgccc-library-manifest.json"),
        ]
    }

    var ignoredItemsURL: URL { sourcesRootURL.appendingPathComponent("ignored-items.json") }
    var ncmConversionsURL: URL { sourcesRootURL.appendingPathComponent("ncm-conversions.json") }
    /// Durable source-aware playlist membership projection. Playlist sidecars
    /// continue to own order; this file owns source/manual/exclusion edges.
    var playlistMembershipsURL: URL {
        sourcesRootURL.appendingPathComponent("playlist-memberships.json")
    }

    func trackFolderURL(for id: UUID) -> URL {
        tracksRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func trackMetaURL(for id: UUID) -> URL {
        trackFolderURL(for: id).appendingPathComponent("meta.json")
    }

    func trackAssetURL(for id: UUID, fileName: String) -> URL? {
        safeFileURL(in: trackFolderURL(for: id), fileName: fileName)
    }

    func trackArtworkURL(for id: UUID, fileName: String) -> URL? {
        trackAssetURL(for: id, fileName: fileName)
    }

    func trackArtworkCandidateFileNames(preferredFileName: String? = nil) -> [String] {
        var names: [String] = []
        if let preferredFileName, isSafeFileComponent(preferredFileName) {
            names.append(preferredFileName)
        }
        if !names.contains(Self.preferredTrackArtworkFileName) {
            names.append(Self.preferredTrackArtworkFileName)
        }
        if !names.contains(Self.legacyTrackArtworkFileName) {
            names.append(Self.legacyTrackArtworkFileName)
        }
        return names
    }

    func trackLyricsURL(for id: UUID, ext: String) -> URL? {
        guard isSafeFileComponent(ext) else { return nil }
        return safeFileURL(in: trackFolderURL(for: id), fileName: "lyrics.\(ext)")
    }

    func trackTTMLLyricsURL(for id: UUID) -> URL {
        trackFolderURL(for: id).appendingPathComponent("lyrics.ttml")
    }

    func playlistURL(for id: UUID) -> URL {
        playlistsRootURL.appendingPathComponent("\(id.uuidString).json")
    }

    func legacyPlaylistArtworkURL(for id: UUID) -> URL {
        playlistsRootURL.appendingPathComponent("\(id.uuidString)_artwork.png")
    }

    func playlistCustomArtworkURL(for id: UUID) -> URL {
        playlistsRootURL.appendingPathComponent("\(id.uuidString)_custom.png")
    }

    func playlistGeneratedArtworkURL(for id: UUID) -> URL {
        playlistsRootURL.appendingPathComponent("\(id.uuidString)_generated.png")
    }

    func playlistAssetURL(fileName: String) -> URL? {
        safeFileURL(in: playlistsRootURL, fileName: fileName)
    }

    func artistFolderURL(for id: UUID) -> URL {
        artistsRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func albumFolderURL(for id: UUID) -> URL {
        albumsRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func artistMetaURL(for id: UUID) -> URL {
        artistFolderURL(for: id).appendingPathComponent("meta.json")
    }

    func albumMetaURL(for id: UUID) -> URL {
        albumFolderURL(for: id).appendingPathComponent("meta.json")
    }

    func sourceRootURL(for id: UUID) -> URL {
        sourcesRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func sourceDescriptorURL(for id: UUID) -> URL {
        sourceRootURL(for: id).appendingPathComponent("source.json")
    }

    func sourceScanManifestURL(for id: UUID) -> URL {
        sourceScanCacheRootURL.appendingPathComponent("\(id.uuidString).json")
    }

    func libraryURL(from relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        return contains(candidate) ? candidate : nil
    }

    func contains(_ candidateURL: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        let candidatePath = candidateURL.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    func createRequiredDirectories(fileManager: FileManager = .default) throws {
        for url in requiredDirectories {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    var requiredDirectories: [URL] {
        [
            settingsRootURL,
            pendingTransactionsRootURL,
            completedTransactionsRootURL,
            tracksRootURL,
            sourcesRootURL,
            playlistsRootURL,
            artistsRootURL,
            albumsRootURL,
            playbackHistoryRootURL,
            indexRootURL,
            artworkCacheRootURL,
            lyricsCacheRootURL,
            colorsCacheRootURL,
            homeCacheRootURL,
            externalPlaybackCacheRootURL,
            importStagingRootURL,
            libraryScanCacheRootURL,
            sourceScanCacheRootURL,
        ]
    }

    private func directory(_ name: String) -> URL {
        rootURL.appendingPathComponent(name, isDirectory: true)
    }

    private func safeFileURL(in directory: URL, fileName: String) -> URL? {
        guard isSafeFileComponent(fileName) else { return nil }
        let candidate = directory.appendingPathComponent(fileName).standardizedFileURL
        let directoryPath = directory.standardizedFileURL.path
        guard candidate.path.hasPrefix(directoryPath + "/") else { return nil }
        return candidate
    }

    private func isSafeFileComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
    }
}
