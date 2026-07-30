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
        externalPlaybackCacheRootURL.appendingPathComponent("Artwork", isDirectory: true)
    }
    var externalPlaybackMetadataURL: URL {
        externalPlaybackCacheRootURL
    }
    var lyricsCacheRootURL: URL { paths.lyricsCacheRootURL }
    var amllDBCacheURL: URL {
        lyricsCacheRootURL.appendingPathComponent("AMLLDB", isDirectory: true)
    }
    var externalPlaybackLyricsURL: URL {
        externalPlaybackCacheRootURL.appendingPathComponent("Lyrics", isDirectory: true)
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
