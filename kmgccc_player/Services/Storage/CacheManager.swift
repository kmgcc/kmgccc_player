//
//  CacheManager.swift
//  myPlayer2
//
//  Central maintenance entry points for app-managed caches.
//

import Darwin
import Foundation
import QuartzCore
import SQLite3

nonisolated struct DiskCacheTrimResult: Sendable, Equatable {
    let removedFileCount: Int
    let removedBytes: Int64

    static let empty = DiskCacheTrimResult(removedFileCount: 0, removedBytes: 0)
}

/// Centralized quota policies for rebuildable on-disk caches.
nonisolated struct DiskCacheBudget: Sendable, Equatable {
    let maxBytes: Int64
    let targetFraction: Double
    let maxAge: TimeInterval?

    init(maxBytes: Int64, targetFraction: Double = 0.80, maxAge: TimeInterval? = nil) {
        self.maxBytes = maxBytes
        self.targetFraction = targetFraction
        self.maxAge = maxAge
    }

    /// Track artwork originals cache: 64 MB.
    /// Only inline artwork (without an on-disk sidecar/track file) is cached here.
    static let trackOriginals = DiskCacheBudget(
        maxBytes: 64 * 1024 * 1024,
        targetFraction: 0.80,
        maxAge: 30 * 24 * 3600
    )

    /// Track playback derivatives: 160 MB.
    /// With compact encoding, this holds ~800-1200 tracks of full playback artwork.
    static let trackDerivatives = DiskCacheBudget(
        maxBytes: 160 * 1024 * 1024,
        targetFraction: 0.80,
        maxAge: 30 * 24 * 3600
    )

    /// Playlist row and header artwork derivatives: 96 MB.
    static let playlistDerivatives = DiskCacheBudget(
        maxBytes: 96 * 1024 * 1024,
        targetFraction: 0.80,
        maxAge: 30 * 24 * 3600
    )

    /// QQMusic candidate cover images: 64 MB.
    /// Automatic candidate images expire after 14 days or when the 64 MB ceiling is reached.
    static let qqMusicImages = DiskCacheBudget(
        maxBytes: 64 * 1024 * 1024,
        targetFraction: 0.75,
        maxAge: 14 * 24 * 3600
    )

    /// QQMusic candidate search metadata: 8 MB.
    static let qqMusicMetadata = DiskCacheBudget(
        maxBytes: 8 * 1024 * 1024,
        targetFraction: 0.75,
        maxAge: 7 * 24 * 3600
    )

    /// External playback downloaded artwork: 48 MB.
    static let externalPlaybackArtwork = DiskCacheBudget(
        maxBytes: 48 * 1024 * 1024,
        targetFraction: 0.80,
        maxAge: 14 * 24 * 3600
    )

    /// Header color analysis cache: 4 MB.
    static let headerColors = DiskCacheBudget(
        maxBytes: 4 * 1024 * 1024,
        targetFraction: 0.80,
        maxAge: 30 * 24 * 3600
    )
}

/// Bounds rebuildable disk caches without making the cache format aware of the
/// individual image or metadata producers.
nonisolated enum DiskCacheRetention {
    static func trim(
        at rootURL: URL,
        maxBytes: Int64,
        targetFraction: Double = 0.80,
        maxAge: TimeInterval? = nil,
        recursive: Bool = false,
        preservedFileNames: Set<String> = [],
        fileManager: FileManager = .default
    ) -> DiskCacheTrimResult {
        guard maxBytes > 0 else { return .empty }
        let urls: [URL]
        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .contentModificationDateKey,
                    .fileSizeKey,
                ],
                options: [.skipsHiddenFiles]
            ) else {
                return .empty
            }
            urls = enumerator.compactMap { $0 as? URL }
        } else {
            guard let immediate = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .contentModificationDateKey,
                    .fileSizeKey,
                ],
                options: [.skipsHiddenFiles]
            ) else {
                return .empty
            }
            urls = immediate
        }

        var records: [(url: URL, size: Int64, modified: Date)] = []
        records.reserveCapacity(urls.count)
        var totalBytes: Int64 = 0
        var removedFileCount = 0
        var removedBytes: Int64 = 0

        let now = Date()
        let cutoffDate = maxAge.map { now.addingTimeInterval(-$0) }

        for url in urls {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
            ), values.isRegularFile == true else {
                continue
            }
            if preservedFileNames.contains(url.lastPathComponent) {
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate ?? .distantPast

            if let cutoff = cutoffDate, modified < cutoff {
                do {
                    try fileManager.removeItem(at: url)
                    removedFileCount += 1
                    removedBytes += size
                } catch {
                    continue
                }
                continue
            }

            totalBytes += size
            records.append((url: url, size: size, modified: modified))
        }

        guard totalBytes > maxBytes else {
            return DiskCacheTrimResult(
                removedFileCount: removedFileCount,
                removedBytes: removedBytes
            )
        }

        let clampedFraction = min(1, max(0, targetFraction))
        let targetBytes = Int64(Double(maxBytes) * clampedFraction)
        var currentBytes = totalBytes

        for record in records.sorted(by: { $0.modified < $1.modified })
        where currentBytes > targetBytes {
            do {
                try fileManager.removeItem(at: record.url)
                currentBytes -= record.size
                removedFileCount += 1
                removedBytes += record.size
            } catch {
                continue
            }
        }

        return DiskCacheTrimResult(
            removedFileCount: removedFileCount,
            removedBytes: removedBytes
        )
    }

    static func directorySize(
        at rootURL: URL,
        recursive: Bool = false,
        fileManager: FileManager = .default
    ) -> (bytes: Int64, fileCount: Int) {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return (0, 0)
        }
        var totalBytes: Int64 = 0
        var fileCount = 0

        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                return (0, 0)
            }
            for case let url as URL in enumerator {
                if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                   values.isRegularFile == true {
                    totalBytes += Int64(values.fileSize ?? 0)
                    fileCount += 1
                }
            }
        } else {
            guard let items = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                return (0, 0)
            }
            for url in items {
                if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                   values.isRegularFile == true {
                    totalBytes += Int64(values.fileSize ?? 0)
                    fileCount += 1
                }
            }
        }

        return (totalBytes, fileCount)
    }
}

nonisolated enum CacheManager {
    static let staleImportStagingAge: TimeInterval = 24 * 60 * 60

    @MainActor
    static func purgeRebuildableMemoryCaches(
        reason: String,
        cacheServices: LibraryCacheServices? = nil
    ) async {
        HomeArtworkMemoryStore.shared.clearMemory()
        HomePlaylistCardCoverStore.shared.clearMemory()
        HomePlaylistPreviewArtworkStore.shared.clearMemory()
        FastArtworkMemoryCache.shared.removeAll()
        await SkinRegistry.releaseCachedResources()
        BKThemeAssets.shared.purgeTransientCaches()

        await ArtworkAssetStore.shared.purgeHydratedImages()
        if let cacheServices {
            await cacheServices.trackArtworkCache.clearMemory()
            cacheServices.headerColorExtractor.clearMemory()
            await cacheServices.artworkDerivativeStore.clearMemory()
            await cacheServices.playlistArtworkPipeline.clearMemory()
        }
        await ArtworkLoader.clearMemoryCache()
        await PlaylistPageModelCacheService.shared.removeAll()
        ThemeStore.shared.clearArtworkColorCache()
        trimProcessMemory()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            trimProcessMemory()
        }

        Log.info(
            "[CacheManager] Purged rebuildable memory caches reason=\(reason)",
            category: .perf
        )
    }

    /// Releases memory owned by the currently visible artwork/skin surfaces.
    ///
    /// Skin transitions and window dismissal can leave several independently
    /// bounded image caches alive at the same time. These values are all
    /// rebuildable from disk or the current track and are safe to drop without
    /// touching library/page caches that would make the next navigation cold.
    @MainActor
    static func purgePresentationMemoryCaches(
        reason: String,
        cacheServices: LibraryCacheServices? = nil
    ) async {
        if !HomeWindowLayoutState.shared.isHomeMode {
            purgeHomePresentationMemoryCaches()
        }
        BKThemeAssets.shared.purgeTransientCaches()
        ArtAssetLoader.shared.purgeCache()
        await ArtworkAssetStore.shared.purgeHydratedImages()
        if let cacheServices {
            await cacheServices.trackArtworkCache.clearMemory()
            await cacheServices.artworkDerivativeStore.clearMemory()
            await cacheServices.playlistArtworkPipeline.clearMemory()
        }
        await ArtworkLoader.clearMemoryCache()
        FastArtworkMemoryCache.shared.removeAll()
        await SkinRegistry.releaseCachedResources()
        ThemeStore.shared.clearArtworkColorCache()
        NativeLyricsSurfaceManager.shared.purgeInactiveRenderingResources()
        URLCache.shared.removeAllCachedResponses()
        CATransaction.begin()
        CATransaction.flush()
        CATransaction.commit()
        trimProcessMemory()

        // CoreAnimation and layer deallocations cascade across several runloop turns.
        // Multiple scheduled trim passes ensure that once the layers and textures are
        // truly released by the graphics server, the dirty pages are returned to the OS kernel.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            CATransaction.flush()
            trimProcessMemory()
            try? await Task.sleep(for: .milliseconds(200))
            CATransaction.flush()
            trimProcessMemory()
            try? await Task.sleep(for: .milliseconds(300))
            CATransaction.flush()
            trimProcessMemory()
        }

        Log.info(
            "[CacheManager] Purged presentation memory caches reason=\(reason)",
            category: .perf
        )
    }

    nonisolated static func trimProcessMemory() {
        sqlite3_release_memory(Int32.max)
        let pressureGoal = 1024 * 1024 * 1024
        var count: UInt32 = 0
        var zonesPtr: UnsafeMutablePointer<vm_address_t>?
        if malloc_get_all_zones(mach_task_self_, nil, &zonesPtr, &count) == KERN_SUCCESS, let zonesPtr {
            for i in 0..<Int(count) {
                if let zone = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(zonesPtr[i])) {
                    malloc_zone_pressure_relief(zone, pressureGoal)
                }
            }
        } else {
            malloc_zone_pressure_relief(nil, pressureGoal)
        }
    }

    @MainActor
    static func purgeHomePresentationMemoryCaches() {
        HomeArtworkPreheater.shared.cancel()
        HomeArtworkMemoryStore.shared.clearMemory()
        clearHomeHeroArtworkMemoryCaches()
        HomePlaylistCardCoverStore.shared.clearMemory()
        HomePlaylistPreviewArtworkStore.shared.clearMemory()
        HomeAmbientShapesBackground.purgeCaches()
    }

    // MARK: - Library disk caches

    /// Cleans one cache category of the open library. In-memory copies go
    /// first so no producer writes a stale entry back afterwards.
    @MainActor
    static func clear(_ category: StorageCategory, services: LibraryCacheServices) async {
        guard category.clearance == .cache else { return }
        let storage = services.storageLocations
        switch category {
        case .artworkCache:
            await ArtworkAssetStore.shared.clearCache()
            await services.trackArtworkCache.clearMemory()
            await services.artworkDerivativeStore.clearAll()
            await services.playlistArtworkPipeline.clearMemory()
            await ArtworkLoader.clearMemoryCache()
            FastArtworkMemoryCache.shared.removeAll()
        case .onlineCache:
            await services.externalPlaybackMetadataStore.clearAutomaticCaches()
            try? await services.amllDBService.clearIndex()
            URLCache.shared.removeAllCachedResponses()
        case .otherCache:
            ThemeStore.shared.clearArtworkColorCache()
            services.headerColorExtractor.clearMemory()
            await removeItems(storage.paths.retiredDataURLs)
            await removeUnregisteredCacheItems(in: storage)
            _ = await cleanupStaleImportStaging(
                roots: [storage.importStagingRootURL],
                reason: "manualClean",
                maxAge: staleImportStagingAge
            )
        default:
            break
        }
        await removeItems(
            LibraryCacheArea.areas(in: category)
                .filter(\.isRemovedWhole)
                .map { $0.url(in: storage) }
        )
        Log.info("[CacheManager] Cleaned category=\(category.rawValue)", category: .perf)
    }

    /// Cleans every cache category of a library that is not open. External
    /// playback results stay, since only the open store knows which artwork
    /// the listener chose.
    static func clearInactiveLibraryCaches(rootURL: URL) async {
        let storage = StorageLocations.scoped(to: LibraryPaths(rootURL: rootURL))
        await removeItems(
            LibraryCacheArea.allCases.filter(\.isRemovedWhole).map { $0.url(in: storage) }
                + storage.paths.retiredDataURLs
        )
        await removeUnregisteredCacheItems(in: storage)
        _ = await cleanupStaleImportStaging(
            roots: [storage.importStagingRootURL],
            reason: "inactiveLibraryClean",
            maxAge: staleImportStagingAge
        )
    }

    /// Entries under `Cache/` that belong to no registered area, such as a
    /// directory an earlier version created.
    nonisolated static func unregisteredCacheItems(in storage: LibraryStorageLocations) -> [URL] {
        let areaPaths = LibraryCacheArea.allCases.map { $0.url(in: storage).standardizedFileURL.path }
        let fileManager = FileManager.default
        var result: [URL] = []
        var pending = [storage.libraryCacheRootURL.standardizedFileURL]
        while let directory = pending.popLast() {
            guard let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }
            for child in children {
                let path = child.standardizedFileURL.path
                if areaPaths.contains(path) { continue }
                if areaPaths.contains(where: { $0.hasPrefix(path + "/") }) {
                    pending.append(child)
                } else {
                    result.append(child)
                }
            }
        }
        return result
    }

    /// Enforces every registered budget, then removes stale import staging
    /// and files earlier versions left behind.
    @discardableResult
    static func trimAllDiskCaches(
        storage: LibraryStorageLocations
    ) async -> DiskCacheTrimResult {
        let result = await Task.detached(priority: .utility) { () -> DiskCacheTrimResult in
            var removedFiles = 0
            var removedBytes: Int64 = 0
            let manualArtwork = ExternalPlaybackMetadataStore.loadManualArtworkFileNames(
                from: storage.externalPlaybackMetadataURL.appendingPathComponent("records.json")
            )
            for area in LibraryCacheArea.allCases {
                let areaURL = area.url(in: storage)
                for rule in area.trimRules {
                    let url = rule.relativePath.map {
                        areaURL.appendingPathComponent($0, isDirectory: true)
                    } ?? areaURL
                    let trimmed = DiskCacheRetention.trim(
                        at: url,
                        maxBytes: rule.budget.maxBytes,
                        targetFraction: rule.budget.targetFraction,
                        maxAge: rule.budget.maxAge,
                        recursive: rule.recursive,
                        preservedFileNames: area == .externalPlayback ? manualArtwork : []
                    )
                    removedFiles += trimmed.removedFileCount
                    removedBytes += trimmed.removedBytes
                }
            }

            let fileManager = FileManager.default
            for url in storage.paths.retiredDataURLs where fileManager.fileExists(atPath: url.path) {
                let size = StorageUsageScanner.allocatedSize(of: url)
                if (try? fileManager.removeItem(at: url)) != nil {
                    removedFiles += 1
                    removedBytes += size
                }
            }
            return DiskCacheTrimResult(removedFileCount: removedFiles, removedBytes: removedBytes)
        }.value

        _ = await cleanupStaleImportStaging(
            roots: [storage.importStagingRootURL],
            reason: "periodicMaintenance",
            maxAge: staleImportStagingAge
        )
        if result.removedFileCount > 0 {
            Log.info(
                "[CacheManager] Disk maintenance removed \(result.removedFileCount) items, freed \(ByteCountFormatter.string(fromByteCount: result.removedBytes, countStyle: .file))",
                category: .perf
            )
        }
        return result
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

    private static func removeUnregisteredCacheItems(in storage: LibraryStorageLocations) async {
        let items = await Task.detached(priority: .utility) {
            unregisteredCacheItems(in: storage)
        }.value
        await removeItems(items)
    }

    private static func removeItems(_ urls: [URL]) async {
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
