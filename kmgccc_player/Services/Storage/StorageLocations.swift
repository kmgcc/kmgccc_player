//
//  StorageLocations.swift
//  myPlayer2
//
//  Central paths for app-managed storage and cache locations.
//

import Foundation

nonisolated struct LibraryStorageLocations: Sendable, Equatable {
    let paths: LibraryPaths

    var libraryRootURL: URL { paths.rootURL }
    var libraryCacheRootURL: URL { paths.cacheRootURL }
    var artworkCacheRootURL: URL { paths.artworkCacheRootURL }
    var playlistArtworkDerivativesURL: URL {
        artworkCacheRootURL.appendingPathComponent("PlaylistDerivatives", isDirectory: true)
    }
    var trackArtworkOriginalsURL: URL {
        artworkCacheRootURL.appendingPathComponent("Tracks", isDirectory: true)
    }
    var trackArtworkDerivativesURL: URL {
        artworkCacheRootURL.appendingPathComponent("Derivatives", isDirectory: true)
    }
    var qqMusicCoverCacheURL: URL {
        artworkCacheRootURL.appendingPathComponent("QQMusic", isDirectory: true)
    }
    var externalPlaybackArtworkURL: URL {
        artworkCacheRootURL.appendingPathComponent("ExternalPlayback", isDirectory: true)
    }
    var lyricsCacheRootURL: URL { paths.lyricsCacheRootURL }
    var amllDBCacheURL: URL {
        lyricsCacheRootURL.appendingPathComponent("AMLLDB", isDirectory: true)
    }
    var externalPlaybackLyricsURL: URL {
        lyricsCacheRootURL.appendingPathComponent("ExternalPlayback", isDirectory: true)
    }
    var colorsCacheURL: URL { paths.colorsCacheRootURL }
    var headerColorCacheURL: URL {
        colorsCacheURL.appendingPathComponent("Header", isDirectory: true)
    }
    var homeCacheURL: URL { paths.homeCacheRootURL }
    var externalPlaybackCacheRootURL: URL { paths.externalPlaybackCacheRootURL }
    var importStagingRootURL: URL { paths.importStagingRootURL }
}

nonisolated enum StorageLocations {
    static func scoped(to paths: LibraryPaths) -> LibraryStorageLocations {
        LibraryStorageLocations(paths: paths)
    }
    static var libraryRootURL: URL {
        LocalLibraryPaths.libraryRootURL
    }

    static var libraryCacheRootURL: URL {
        libraryRootURL.appendingPathComponent("Cache", isDirectory: true)
    }

    static var artworkCacheRootURL: URL {
        libraryCacheRootURL.appendingPathComponent("Artwork", isDirectory: true)
    }

    static var playlistArtworkDerivativesURL: URL {
        artworkCacheRootURL.appendingPathComponent("PlaylistDerivatives", isDirectory: true)
    }

    static var trackArtworkOriginalsURL: URL {
        artworkCacheRootURL.appendingPathComponent("Tracks", isDirectory: true)
    }

    static var trackArtworkDerivativesURL: URL {
        artworkCacheRootURL.appendingPathComponent("Derivatives", isDirectory: true)
    }

    static var qqMusicCoverCacheURL: URL {
        artworkCacheRootURL.appendingPathComponent("QQMusic", isDirectory: true)
    }

    static var externalPlaybackArtworkURL: URL {
        artworkCacheRootURL.appendingPathComponent("ExternalPlayback", isDirectory: true)
    }

    static var lyricsCacheRootURL: URL {
        libraryCacheRootURL.appendingPathComponent("Lyrics", isDirectory: true)
    }

    static var amllDBCacheURL: URL {
        lyricsCacheRootURL.appendingPathComponent("AMLLDB", isDirectory: true)
    }

    static var externalPlaybackLyricsURL: URL {
        lyricsCacheRootURL.appendingPathComponent("ExternalPlayback", isDirectory: true)
    }

    static var colorsCacheURL: URL {
        libraryCacheRootURL.appendingPathComponent("Colors", isDirectory: true)
    }

    static var headerColorCacheURL: URL {
        colorsCacheURL.appendingPathComponent("Header", isDirectory: true)
    }

    static var homeCacheURL: URL {
        libraryCacheRootURL.appendingPathComponent("Home", isDirectory: true)
    }

    static var importStagingRootURL: URL {
        libraryCacheRootURL.appendingPathComponent("ImportStaging", isDirectory: true)
    }

    static var legacyImportStagingRootURL: URL {
        libraryRootURL.appendingPathComponent("ImportStaging", isDirectory: true)
    }

    static var legacyAppCacheRootURL: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("kmgccc_player", isDirectory: true)
    }

    static var legacyPlaylistArtworkDerivativesURL: URL {
        legacyAppCacheRootURL.appendingPathComponent("PlaylistArtworkDerivatives", isDirectory: true)
    }

    static var legacyQQMusicCoverCacheURL: URL {
        legacyAppCacheRootURL.appendingPathComponent("QQMusicCoverCache", isDirectory: true)
    }

    static var legacyExternalPlaybackArtworkURL: URL {
        legacyAppCacheRootURL.appendingPathComponent("ExternalPlaybackArtwork", isDirectory: true)
    }

    static var legacyColorsCacheURL: URL {
        legacyAppCacheRootURL.appendingPathComponent("Colors", isDirectory: true)
    }

    static var legacyHomeCacheURL: URL {
        legacyAppCacheRootURL.appendingPathComponent("Home", isDirectory: true)
    }

    static var legacyAMLLDBCacheURL: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("AMLLDB", isDirectory: true)
    }

    static var bundleCachesURL: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent(Bundle.main.bundleIdentifier ?? "kmgccc.player", isDirectory: true)
    }

    static var httpStoragesRootURL: URL {
        let root = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library", isDirectory: true)
        return root.appendingPathComponent("HTTPStorages", isDirectory: true)
    }
}
