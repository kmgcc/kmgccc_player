//
//  CacheManager.swift
//  myPlayer2
//
//  Central maintenance entry points for app-managed caches.
//

import Foundation

struct LegacyCacheCleanupResult: Sendable {
    var removedDirectories: Int
    var failedDirectories: Int
    var removedImportStagingSessions: Int
    var failedImportStagingSessions: Int

    static let empty = LegacyCacheCleanupResult(
        removedDirectories: 0,
        failedDirectories: 0,
        removedImportStagingSessions: 0,
        failedImportStagingSessions: 0
    )

    var removedItemCount: Int {
        removedDirectories + removedImportStagingSessions
    }

    var failedItemCount: Int {
        failedDirectories + failedImportStagingSessions
    }
}

nonisolated enum CacheManager {
    static let staleImportStagingAge: TimeInterval = 24 * 60 * 60

    static func clearLibraryCaches() async {
        await ArtworkAssetStore.shared.clearCache()
        await TrackArtworkCache.shared.clearMemory()
        await ArtworkDerivativeCacheStore.shared.clearAll()
        await ThemeStore.shared.clearArtworkColorCache()
        await ExternalPlaybackMetadataStore.shared.clearAutomaticCaches()
        try? await AMLLDBRawIndexCache.shared.clearCache()

        await removeDirectories(libraryCacheDirectories)
        await removeDirectories(legacyCacheDirectories)
        await cleanupStaleImportStaging(reason: "manualLibraryCacheClear", maxAge: 0)
    }

    static func hasBuild7LegacyCaches() async -> Bool {
        let paths = build7LegacyCacheDetectionDirectories.map(\.path)
        let hasLegacyDirectory = await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            return paths.contains { path in
                guard fileManager.fileExists(atPath: path) else { return false }
                let children = try? fileManager.contentsOfDirectory(atPath: path)
                return children?.isEmpty == false
            }
        }.value

        if hasLegacyDirectory { return true }

        let hasLegacyStaging = await hasStaleImportStaging(
            roots: [StorageLocations.legacyImportStagingRootURL],
            maxAge: staleImportStagingAge
        )
        if hasLegacyStaging { return true }

        return await ExternalPlaybackMetadataStore.shared.hasAutomaticCacheData
    }

    static func clearBuild7LegacyCaches() async -> LegacyCacheCleanupResult {
        await ExternalPlaybackMetadataStore.shared.clearBuild7LegacyAutomaticCaches()
        await ThemeStore.shared.clearArtworkColorCache()

        let directorySummary = await removeDirectoriesWithResult(build7LegacyCacheDirectories)
        let stagingSummary = await cleanupStaleImportStaging(
            roots: [StorageLocations.legacyImportStagingRootURL],
            reason: "build7LegacyCacheCleanup",
            maxAge: staleImportStagingAge
        )

        return LegacyCacheCleanupResult(
            removedDirectories: directorySummary.removed,
            failedDirectories: directorySummary.failed,
            removedImportStagingSessions: stagingSummary.deleted,
            failedImportStagingSessions: stagingSummary.failed
        )
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
        _ = await cleanupStaleImportStaging(roots: roots, reason: reason, maxAge: maxAge)
    }

    private static func cleanupStaleImportStaging(
        roots: [URL],
        reason: String,
        maxAge: TimeInterval
    ) async -> (deleted: Int, failed: Int) {
        let paths = uniqueURLs(roots).map(\.path)
        return await Task.detached(priority: .utility) {
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
            return (deleted, failed)
        }.value
    }

    private static var libraryCacheDirectories: [URL] {
        [
            StorageLocations.playlistArtworkDerivativesURL,
            StorageLocations.trackArtworkOriginalsURL,
            StorageLocations.trackArtworkDerivativesURL,
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
            StorageLocations.legacyColorsCacheURL,
            StorageLocations.legacyHomeCacheURL,
            StorageLocations.legacyAMLLDBCacheURL
        ]
    }

    private static var build7LegacyCacheDirectories: [URL] {
        legacyCacheDirectories
    }

    private static var build7LegacyCacheDetectionDirectories: [URL] {
        build7LegacyCacheDirectories + [
            StorageLocations.legacyExternalPlaybackArtworkURL
        ]
    }

    private static func removeDirectories(_ urls: [URL]) async {
        _ = await removeDirectoriesWithResult(urls)
    }

    private static func removeDirectoriesWithResult(_ urls: [URL]) async -> (removed: Int, failed: Int) {
        let paths = uniqueURLs(urls).map(\.path)
        return await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var removed = 0
            var failed = 0
            for path in paths where fileManager.fileExists(atPath: path) {
                do {
                    try fileManager.removeItem(atPath: path)
                    removed += 1
                } catch {
                    failed += 1
                }
            }
            return (removed, failed)
        }.value
    }

    private static func hasStaleImportStaging(roots: [URL], maxAge: TimeInterval) async -> Bool {
        let paths = uniqueURLs(roots).map(\.path)
        return await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let cutoff = Date().addingTimeInterval(-maxAge)
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
                    if isEmpty || modified < cutoff {
                        return true
                    }
                }
            }
            return false
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
