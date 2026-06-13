//
//  CacheManager.swift
//  myPlayer2
//
//  Central maintenance entry points for app-managed caches.
//

import Foundation

nonisolated enum CacheManager {
    static let staleImportStagingAge: TimeInterval = 24 * 60 * 60

    static func clearLibraryCaches() async {
        await ArtworkAssetStore.shared.clearCache()
        await ArtworkDerivativeCacheStore.shared.clearAll()
        await ThemeStore.shared.clearArtworkColorCache()
        await ExternalPlaybackMetadataStore.shared.clearAutomaticCaches()
        try? await AMLLDBRawIndexCache.shared.clearCache()

        await removeDirectories(libraryCacheDirectories)
        await removeDirectories(legacyCacheDirectories)
        await cleanupStaleImportStaging(reason: "manualLibraryCacheClear", maxAge: 0)
    }

    static func cleanupStaleImportStaging(
        reason: String,
        maxAge: TimeInterval = staleImportStagingAge
    ) async {
        let snapshot = await LibraryImportCoordinator.shared.snapshot()
        guard !snapshot.isImporting else {
            Log.debug(
                "[CacheManager] skip ImportStaging cleanup reason=\(reason) activeImport=true",
                category: .import
            )
            return
        }

        let roots = uniqueURLs([
            StorageLocations.importStagingRootURL,
            StorageLocations.legacyImportStagingRootURL
        ])
        let paths = roots.map(\.path)
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let cutoff = Date().addingTimeInterval(-maxAge)
            var deleted = 0
            var failed = 0

            for path in paths {
                let root = URL(fileURLWithPath: path, isDirectory: true)
                guard let children = try? fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for url in children {
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                    guard values?.isDirectory == true else { continue }

                    let nested = (try? fileManager.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    let isEmpty = nested.isEmpty
                    let modified = values?.contentModificationDate ?? .distantPast
                    guard isEmpty || modified < cutoff else { continue }

                    do {
                        try fileManager.removeItem(at: url)
                        deleted += 1
                    } catch {
                        failed += 1
                    }
                }
            }

            Log.debug(
                "[CacheManager] ImportStaging cleanup reason=\(reason) deleted=\(deleted) failed=\(failed)",
                category: .import
            )
        }.value
    }

    private static var libraryCacheDirectories: [URL] {
        [
            StorageLocations.playlistArtworkDerivativesURL,
            StorageLocations.qqMusicCoverCacheURL,
            StorageLocations.lyricsCacheRootURL,
            StorageLocations.colorsCacheURL,
            StorageLocations.homeCacheURL
        ]
    }

    private static var legacyCacheDirectories: [URL] {
        [
            StorageLocations.legacyPlaylistArtworkDerivativesURL,
            StorageLocations.legacyQQMusicCoverCacheURL,
            StorageLocations.legacyHomeCacheURL,
            StorageLocations.legacyAMLLDBCacheURL
        ]
    }

    private static func removeDirectories(_ urls: [URL]) async {
        let paths = uniqueURLs(urls).map(\.path)
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            for path in paths where fileManager.fileExists(atPath: path) {
                try? fileManager.removeItem(atPath: path)
            }
        }.value
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let standardized = url.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                result.append(standardized)
            }
        }
        return result
    }
}
