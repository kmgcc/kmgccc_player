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

nonisolated struct LegacyCacheMigrationResult: Sendable, Equatable {
    let migratedDirectories: Int
    let skippedDirectories: Int
    let failedDirectories: Int
}

nonisolated enum CacheManager {
    static let staleImportStagingAge: TimeInterval = 24 * 60 * 60

    static func clearLibraryCaches(
        storageLocations: LibraryStorageLocations,
        trackArtworkCache: TrackArtworkCache,
        artworkDerivativeStore: ArtworkDerivativeCacheStore,
        amllDBService: AMLLDBService,
        externalPlaybackMetadataStore: ExternalPlaybackMetadataStore
    ) async {
        let legacyLocations = LegacyLibraryStorageLocations.system()
        await ArtworkAssetStore.shared.clearCache()
        await trackArtworkCache.clearMemory()
        await artworkDerivativeStore.clearAll()
        await ThemeStore.shared.clearArtworkColorCache()
        await externalPlaybackMetadataStore.clearAutomaticCaches()
        try? await amllDBService.clearIndex()

        await removeDirectories(libraryCacheDirectories(for: storageLocations))
        await removeDirectories(legacyCacheDirectories(at: legacyLocations))
        _ = await cleanupStaleImportStaging(
            roots: [
                storageLocations.importStagingRootURL,
                storageLocations.libraryRootURL.appendingPathComponent(
                    "ImportStaging",
                    isDirectory: true
                ),
            ],
            reason: "manualLibraryCacheClear",
            maxAge: 0
        )
    }

    static func hasBuild7LegacyCaches() async -> Bool {
        let legacyLocations = LegacyLibraryStorageLocations.system()
        let paths = build7LegacyCacheDetectionDirectories(at: legacyLocations).map(\.path)
        let hasLegacyDirectory = await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            return paths.contains { path in
                guard fileManager.fileExists(atPath: path) else { return false }
                let children = try? fileManager.contentsOfDirectory(atPath: path)
                return children?.isEmpty == false
            }
        }.value

        if hasLegacyDirectory { return true }

        return false
    }

    static func clearBuild7LegacyCaches() async -> LegacyCacheCleanupResult {
        let legacyLocations = LegacyLibraryStorageLocations.system()
        await ThemeStore.shared.clearArtworkColorCache()

        let directorySummary = await removeDirectoriesWithResult(
            build7LegacyCacheDirectories(at: legacyLocations)
        )
        return LegacyCacheCleanupResult(
            removedDirectories: directorySummary.removed,
            failedDirectories: directorySummary.failed,
            removedImportStagingSessions: 0,
            failedImportStagingSessions: 0
        )
    }

    static func migrateLegacyCaches(
        to storage: LibraryStorageLocations,
        stagingRootURL: URL,
        legacyLocations: LegacyLibraryStorageLocations
    ) async -> LegacyCacheMigrationResult {
        let mappings = legacyCacheMappings(
            storage: storage,
            legacyLocations: legacyLocations
        ).map { (source: $0.source.path, destination: $0.destination.path) }
        let stagingPath = stagingRootURL
            .appendingPathComponent("LegacyCacheMigration", isDirectory: true)
            .path
        return await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let stagingRoot = URL(fileURLWithPath: stagingPath, isDirectory: true)
            try? fileManager.removeItem(at: stagingRoot)
            var migrated = 0
            var skipped = 0
            var failed = 0

            do {
                try fileManager.createDirectory(
                    at: stagingRoot,
                    withIntermediateDirectories: true
                )
            } catch {
                let existingSources = mappings.reduce(into: 0) { count, mapping in
                    if fileManager.fileExists(atPath: mapping.source) {
                        count += 1
                    }
                }
                return LegacyCacheMigrationResult(
                    migratedDirectories: 0,
                    skippedDirectories: 0,
                    failedDirectories: existingSources
                )
            }
            defer { try? fileManager.removeItem(at: stagingRoot) }

            for (index, mapping) in mappings.enumerated() {
                let source = URL(fileURLWithPath: mapping.source, isDirectory: true)
                let destination = URL(fileURLWithPath: mapping.destination, isDirectory: true)
                guard fileManager.fileExists(atPath: source.path) else { continue }

                let staged = stagingRoot.appendingPathComponent(
                    "\(index)-\(UUID().uuidString)",
                    isDirectory: true
                )
                do {
                    let destinationExisted = fileManager.fileExists(atPath: destination.path)
                    try fileManager.copyItem(at: source, to: staged)
                    let sourceInventory = try directoryInventory(at: source)
                    guard sourceInventory == (try directoryInventory(at: staged)) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    try fileManager.createDirectory(
                        at: destination,
                        withIntermediateDirectories: true
                    )

                    let merge = try mergeMissingFiles(
                        from: staged,
                        to: destination,
                        inventory: sourceInventory,
                        fileManager: fileManager
                    )
                    if destinationExisted && merge.copiedFiles == 0 {
                        skipped += 1
                    } else {
                        migrated += 1
                    }
                } catch {
                    failed += 1
                }
                try? fileManager.removeItem(at: staged)
            }
            return LegacyCacheMigrationResult(
                migratedDirectories: migrated,
                skippedDirectories: skipped,
                failedDirectories: failed
            )
        }.value
    }

    static func removeLegacyIndexes(
        at legacyLocations: LegacyLibraryStorageLocations
    ) async -> Bool {
        let paths = (
            legacyLocations.legacyTrackIndexURLs
                + legacyLocations.legacySearchIndexURLs
        ).map(\.path)
        let rootPath = legacyLocations.legacyIndexRootURL.path
        return await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var succeeded = true
            for path in paths where fileManager.fileExists(atPath: path) {
                do {
                    try fileManager.removeItem(atPath: path)
                } catch {
                    succeeded = false
                }
            }
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            if let children = try? fileManager.contentsOfDirectory(atPath: root.path),
               children.isEmpty {
                try? fileManager.removeItem(at: root)
            }
            return succeeded
        }.value
    }

    static func removeMigratedLegacyCaches(
        at legacyLocations: LegacyLibraryStorageLocations
    ) async {
        let directories = [
            legacyLocations.legacyPlaylistArtworkURL,
            legacyLocations.legacyQQMusicCoverURL,
            legacyLocations.legacyExternalPlaybackArtworkURL,
            legacyLocations.legacyColorsURL,
            legacyLocations.legacyHomeURL,
            legacyLocations.legacyAMLLDBURL,
        ]
        await removeDirectories(directories)
    }

    static func removeLegacyImportStaging(at libraryRootURL: URL) async {
        await removeDirectories([
            libraryRootURL.appendingPathComponent("ImportStaging", isDirectory: true)
        ])
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

    private static func libraryCacheDirectories(for locations: LibraryStorageLocations) -> [URL] {
        [
            locations.playlistArtworkDerivativesURL,
            locations.trackArtworkOriginalsURL,
            locations.trackArtworkDerivativesURL,
            locations.qqMusicCoverCacheURL,
            locations.lyricsCacheRootURL,
            locations.colorsCacheURL,
            locations.homeCacheURL
        ]
    }

    private static func legacyCacheDirectories(
        at locations: LegacyLibraryStorageLocations
    ) -> [URL] {
        [
            locations.legacyPlaylistArtworkURL,
            locations.legacyQQMusicCoverURL,
            locations.legacyExternalPlaybackArtworkURL,
            locations.legacyColorsURL,
            locations.legacyHomeURL,
            locations.legacyAMLLDBURL,
        ]
    }

    private static func build7LegacyCacheDirectories(
        at locations: LegacyLibraryStorageLocations
    ) -> [URL] {
        legacyCacheDirectories(at: locations)
    }

    private static func build7LegacyCacheDetectionDirectories(
        at locations: LegacyLibraryStorageLocations
    ) -> [URL] {
        build7LegacyCacheDirectories(at: locations)
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

    private static func legacyCacheMappings(
        storage: LibraryStorageLocations,
        legacyLocations: LegacyLibraryStorageLocations
    ) -> [(source: URL, destination: URL)] {
        [
            (
                legacyLocations.legacyPlaylistArtworkURL,
                storage.playlistArtworkDerivativesURL
            ),
            (
                legacyLocations.legacyQQMusicCoverURL,
                storage.qqMusicCoverCacheURL
            ),
            (
                legacyLocations.legacyExternalPlaybackArtworkURL,
                storage.externalPlaybackArtworkURL
            ),
            (
                legacyLocations.legacyColorsURL,
                storage.colorsCacheURL
            ),
            (
                legacyLocations.legacyHomeURL,
                storage.homeCacheURL
            ),
            (
                legacyLocations.legacyAMLLDBURL,
                storage.amllDBCacheURL
            ),
        ]
    }

    private nonisolated static func directoryInventory(
        at root: URL
    ) throws -> [String: Int64] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }
        var inventory: [String: Int64] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let prefix = root.standardizedFileURL.path + "/"
            guard url.standardizedFileURL.path.hasPrefix(prefix) else { continue }
            let relativePath = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            inventory[relativePath] = Int64(values.fileSize ?? 0)
        }
        return inventory
    }

    private nonisolated static func mergeMissingFiles(
        from stagedRoot: URL,
        to destinationRoot: URL,
        inventory: [String: Int64],
        fileManager: FileManager
    ) throws -> (copiedFiles: Int, preservedFiles: Int) {
        var copiedFiles = 0
        var preservedFiles = 0
        var createdFiles: [URL] = []

        do {
            for relativePath in inventory.keys.sorted() {
                let stagedFile = stagedRoot.appendingPathComponent(relativePath)
                let destinationFile = destinationRoot.appendingPathComponent(relativePath)
                if fileManager.fileExists(atPath: destinationFile.path) {
                    preservedFiles += 1
                    continue
                }

                try fileManager.createDirectory(
                    at: destinationFile.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                do {
                    try fileManager.copyItem(at: stagedFile, to: destinationFile)
                    createdFiles.append(destinationFile)
                } catch {
                    // A cache owner may publish the same file while migration is
                    // running. Its newer result wins and must never be overwritten.
                    if fileManager.fileExists(atPath: destinationFile.path) {
                        preservedFiles += 1
                        continue
                    }
                    throw error
                }

                let values = try destinationFile.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                )
                guard values.isRegularFile == true,
                      Int64(values.fileSize ?? 0) == inventory[relativePath] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                copiedFiles += 1
            }
        } catch {
            for url in createdFiles {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }

        return (copiedFiles, preservedFiles)
    }
}
