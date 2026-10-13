//
//  StorageCategory.swift
//  kmgccc_player
//
//  The one registry of what the App stores and how each part may be cleaned.
//  Usage statistics, budget trimming, manual cleaning and the Storage page
//  all read this table; a new cache is registered here once.
//

import Foundation

/// How the Storage page may clean a category.
nonisolated enum StorageClearance: Sendable, Equatable {
    /// Library or listener data; never cleaned as a cache.
    case none
    /// Rebuilt from the library at a noticeable cost, cleaned on its own.
    case rebuild
    /// Rebuilt on demand at little cost.
    case cache
}

/// One segment of the Storage bar.
nonisolated enum StorageCategory: String, CaseIterable, Sendable, Identifiable {
    /// Audio copied into a managed library.
    case music
    /// Audio a referenced library plays from its source folders.
    case externalMusic
    /// Song, playlist, artist and album records, covers, lyrics and history.
    case libraryContent
    /// Track and search indexes, scan records and loudness measurements.
    case indexes
    case artworkCache
    /// Online candidates, external playback results and the lyrics database.
    case onlineCache
    /// Colours, the Home snapshot, import staging and retired files.
    case otherCache
    /// Settings, presets, skins and reports kept outside any library.
    case appData

    var id: String { rawValue }

    var clearance: StorageClearance {
        switch self {
        case .music, .externalMusic, .libraryContent, .appData: .none
        case .indexes: .rebuild
        case .artworkCache, .onlineCache, .otherCache: .cache
        }
    }

    /// Categories one "clean all" removes.
    static let cacheCategories: [StorageCategory] = allCases.filter { $0.clearance == .cache }
}

/// Size policy for one directory inside a cache area.
nonisolated struct DiskCacheTrimRule: Sendable {
    /// Directory relative to the area root, or nil for the root itself.
    let relativePath: String?
    let budget: DiskCacheBudget
    let recursive: Bool

    init(_ relativePath: String? = nil, budget: DiskCacheBudget, recursive: Bool = false) {
        self.relativePath = relativePath
        self.budget = budget
        self.recursive = recursive
    }
}

/// Every directory under a library's `Cache/`. Areas never overlap, so
/// summing them never counts a file twice.
nonisolated enum LibraryCacheArea: String, CaseIterable, Sendable {
    case trackArtworkOriginals
    case trackArtworkDerivatives
    case playlistArtworkDerivatives
    case onlineArtwork
    case externalPlayback
    case lyricsDatabase
    case colors
    case home
    case importStaging
    case libraryScan
    case sourceScan
    case loudness

    var category: StorageCategory {
        switch self {
        case .trackArtworkOriginals, .trackArtworkDerivatives, .playlistArtworkDerivatives:
            .artworkCache
        case .onlineArtwork, .externalPlayback, .lyricsDatabase:
            .onlineCache
        case .colors, .home, .importStaging:
            .otherCache
        case .libraryScan, .sourceScan, .loudness:
            .indexes
        }
    }

    func url(in storage: LibraryStorageLocations) -> URL {
        switch self {
        case .trackArtworkOriginals: storage.trackArtworkOriginalsURL
        case .trackArtworkDerivatives: storage.trackArtworkDerivativesURL
        case .playlistArtworkDerivatives: storage.playlistArtworkDerivativesURL
        case .onlineArtwork: storage.qqMusicCoverCacheURL
        case .externalPlayback: storage.externalPlaybackCacheRootURL
        case .lyricsDatabase: storage.lyricsCacheRootURL
        case .colors: storage.colorsCacheURL
        case .home: storage.homeCacheURL
        case .importStaging: storage.importStagingRootURL
        case .libraryScan: storage.libraryScanCacheRootURL
        case .sourceScan: storage.sourceScanCacheRootURL
        case .loudness: storage.paths.loudnessCacheRootURL
        }
    }

    /// Size limits enforced by maintenance. Producers trim on write with the
    /// same budgets, so maintenance only catches what a session left behind.
    var trimRules: [DiskCacheTrimRule] {
        switch self {
        case .trackArtworkOriginals: [DiskCacheTrimRule(budget: .trackOriginals)]
        case .trackArtworkDerivatives: [DiskCacheTrimRule(budget: .trackDerivatives)]
        case .playlistArtworkDerivatives: [DiskCacheTrimRule(budget: .playlistDerivatives)]
        case .onlineArtwork:
            [
                DiskCacheTrimRule("Images", budget: .qqMusicImages),
                DiskCacheTrimRule("Metadata", budget: .qqMusicMetadata),
            ]
        case .externalPlayback: [DiskCacheTrimRule("Artwork", budget: .externalPlaybackArtwork)]
        case .colors: [DiskCacheTrimRule("Header", budget: .headerColors)]
        case .lyricsDatabase, .home, .importStaging, .libraryScan, .sourceScan, .loudness: []
        }
    }

    /// Whether cleaning removes the whole directory. External playback keeps
    /// the listener's manual artwork and is cleaned by its store; staging
    /// only loses sessions that are no longer written.
    var isRemovedWhole: Bool {
        switch self {
        case .externalPlayback, .importStaging: false
        default: category.clearance == .cache
        }
    }

    static func areas(in category: StorageCategory) -> [LibraryCacheArea] {
        allCases.filter { $0.category == category }
    }
}

/// App-level storage outside every library.
nonisolated enum AppStorageLocations {
    /// URLSession's response cache, emptied through `URLCache`.
    static var networkCacheURL: URL { StorageLocations.bundleCachesURL }

    static var appDataURLs: [URL] {
        let fileManager = FileManager.default
        let bundleID = Bundle.main.bundleIdentifier ?? "kmgccc.player"
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        return [
            support.appendingPathComponent(bundleID, isDirectory: true),
            support.appendingPathComponent("kmgccc_player", isDirectory: true),
            StorageLocations.httpStoragesRootURL.appendingPathComponent(bundleID, isDirectory: true),
            library.appendingPathComponent("WebKit", isDirectory: true)
                .appendingPathComponent(bundleID, isDirectory: true),
        ]
    }
}
