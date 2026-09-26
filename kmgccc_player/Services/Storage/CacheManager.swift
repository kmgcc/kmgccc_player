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

    /// App-wide recommended total disk cache ceiling (~444 MB).
    static let totalCeilingBytes: Int64 =
        trackOriginals.maxBytes +
        trackDerivatives.maxBytes +
        playlistDerivatives.maxBytes +
        qqMusicImages.maxBytes +
        qqMusicMetadata.maxBytes +
        externalPlaybackArtwork.maxBytes +
        headerColors.maxBytes
}

nonisolated struct DiskCacheUsageSummary: Sendable, Equatable {
    let trackOriginalsBytes: Int64
    let trackDerivativesBytes: Int64
    let playlistDerivativesBytes: Int64
    let qqMusicCoverBytes: Int64
    let externalPlaybackArtworkBytes: Int64
    let colorsBytes: Int64
    let otherBytes: Int64
    let totalBytes: Int64
    let totalFileCount: Int

    static let zero = DiskCacheUsageSummary(
        trackOriginalsBytes: 0,
        trackDerivativesBytes: 0,
        playlistDerivativesBytes: 0,
        qqMusicCoverBytes: 0,
        externalPlaybackArtworkBytes: 0,
        colorsBytes: 0,
        otherBytes: 0,
        totalBytes: 0,
        totalFileCount: 0
    )

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
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

    @MainActor
    static func purgeRebuildableMemoryCaches(
        reason: String,
        cacheServices: LibraryCacheServices? = nil
    ) async {
        HomeArtworkMemoryStore.shared.clearMemory()
        HomePlaylistCardCoverStore.shared.clearMemory()
        HomePlaylistPreviewArtworkStore.shared.clearMemory()
        FastArtworkMemoryCache.shared.removeAll()
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
        await CassetteArtworkCache.shared.removeAll()
        await ClassicArtworkFrameExtendedArtworkCache.shared.removeAll()
        ClassicArtworkFrameExtendedArtworkRenderer.clearCaches()
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
        await CoverGradientBlurMemory.clear()
        await ClassicArtworkFrameExtendedArtworkCache.shared.removeAll()
        ClassicArtworkFrameExtendedArtworkRenderer.clearCaches()
        await ArtworkAssetStore.shared.purgeHydratedImages()
        if let cacheServices {
            await cacheServices.trackArtworkCache.clearMemory()
            await cacheServices.artworkDerivativeStore.clearMemory()
            await cacheServices.playlistArtworkPipeline.clearMemory()
        }
        await ArtworkLoader.clearMemoryCache()
        FastArtworkMemoryCache.shared.removeAll()
        await CassetteArtworkCache.shared.removeAll()
        KmgcccCassetteSkin.purgeCaches()
        RotatingCoverSkin.purgeCaches()
        ThemeStore.shared.clearArtworkColorCache()
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

        // Flush system URLCache so network image responses don't stay cached in ~/Library/Caches
        URLCache.shared.removeAllCachedResponses()

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

    /// Calculates current disk cache usage for all app-managed cache directories.
    static func calculateLibraryDiskCacheUsage(
        storage: LibraryStorageLocations
    ) async -> DiskCacheUsageSummary {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let originals = DiskCacheRetention.directorySize(at: storage.trackArtworkOriginalsURL, fileManager: fileManager)
            let derivatives = DiskCacheRetention.directorySize(at: storage.trackArtworkDerivativesURL, fileManager: fileManager)
            let playlistDerivatives = DiskCacheRetention.directorySize(at: storage.playlistArtworkDerivativesURL, fileManager: fileManager)
            let qqMusic = DiskCacheRetention.directorySize(at: storage.qqMusicCoverCacheURL, recursive: true, fileManager: fileManager)
            let extPlayback = DiskCacheRetention.directorySize(at: storage.externalPlaybackCacheRootURL, recursive: true, fileManager: fileManager)
            let colors = DiskCacheRetention.directorySize(at: storage.colorsCacheURL, recursive: true, fileManager: fileManager)

            // Accurately capture total cache root footprint (including staging, scan caches, lyrics, and home)
            let overall = DiskCacheRetention.directorySize(at: storage.libraryCacheRootURL, recursive: true, fileManager: fileManager)
            let knownBytes = originals.bytes + derivatives.bytes + playlistDerivatives.bytes + qqMusic.bytes + extPlayback.bytes + colors.bytes
            let otherBytes = max(0, overall.bytes - knownBytes)

            return DiskCacheUsageSummary(
                trackOriginalsBytes: originals.bytes,
                trackDerivativesBytes: derivatives.bytes,
                playlistDerivativesBytes: playlistDerivatives.bytes,
                qqMusicCoverBytes: qqMusic.bytes,
                externalPlaybackArtworkBytes: extPlayback.bytes,
                colorsBytes: colors.bytes,
                otherBytes: otherBytes,
                totalBytes: overall.bytes > 0 ? overall.bytes : knownBytes,
                totalFileCount: overall.fileCount > 0 ? overall.fileCount : (originals.fileCount + derivatives.fileCount + playlistDerivatives.fileCount + qqMusic.fileCount + extPlayback.fileCount + colors.fileCount)
            )
        }.value
    }

    /// Enforces disk cache budgets across all app-managed cache directories.
    @discardableResult
    static func trimAllDiskCaches(
        storage: LibraryStorageLocations
    ) async -> DiskCacheTrimResult {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var removedFiles = 0
            var removedBytes: Int64 = 0

            func applyTrim(_ result: DiskCacheTrimResult) {
                removedFiles += result.removedFileCount
                removedBytes += result.removedBytes
            }

            // 1. Track originals & derivatives
            applyTrim(DiskCacheRetention.trim(
                at: storage.trackArtworkOriginalsURL,
                maxBytes: DiskCacheBudget.trackOriginals.maxBytes,
                targetFraction: DiskCacheBudget.trackOriginals.targetFraction,
                maxAge: DiskCacheBudget.trackOriginals.maxAge,
                fileManager: fileManager
            ))
            applyTrim(DiskCacheRetention.trim(
                at: storage.trackArtworkDerivativesURL,
                maxBytes: DiskCacheBudget.trackDerivatives.maxBytes,
                targetFraction: DiskCacheBudget.trackDerivatives.targetFraction,
                maxAge: DiskCacheBudget.trackDerivatives.maxAge,
                fileManager: fileManager
            ))

            // 2. Playlist derivatives
            applyTrim(DiskCacheRetention.trim(
                at: storage.playlistArtworkDerivativesURL,
                maxBytes: DiskCacheBudget.playlistDerivatives.maxBytes,
                targetFraction: DiskCacheBudget.playlistDerivatives.targetFraction,
                maxAge: DiskCacheBudget.playlistDerivatives.maxAge,
                fileManager: fileManager
            ))

            // 3. QQMusic covers (Images & Metadata)
            applyTrim(DiskCacheRetention.trim(
                at: storage.qqMusicCoverCacheURL.appendingPathComponent("Images", isDirectory: true),
                maxBytes: DiskCacheBudget.qqMusicImages.maxBytes,
                targetFraction: DiskCacheBudget.qqMusicImages.targetFraction,
                maxAge: DiskCacheBudget.qqMusicImages.maxAge,
                fileManager: fileManager
            ))
            applyTrim(DiskCacheRetention.trim(
                at: storage.qqMusicCoverCacheURL.appendingPathComponent("Metadata", isDirectory: true),
                maxBytes: DiskCacheBudget.qqMusicMetadata.maxBytes,
                targetFraction: DiskCacheBudget.qqMusicMetadata.targetFraction,
                maxAge: DiskCacheBudget.qqMusicMetadata.maxAge,
                fileManager: fileManager
            ))

            // 4. External playback artwork (preserving user manual overrides)
            let manualArtwork = ExternalPlaybackMetadataStore.loadManualArtworkFileNames(
                from: storage.externalPlaybackMetadataURL.appendingPathComponent("records.json")
            )
            applyTrim(DiskCacheRetention.trim(
                at: storage.externalPlaybackArtworkURL,
                maxBytes: DiskCacheBudget.externalPlaybackArtwork.maxBytes,
                targetFraction: DiskCacheBudget.externalPlaybackArtwork.targetFraction,
                maxAge: DiskCacheBudget.externalPlaybackArtwork.maxAge,
                preservedFileNames: manualArtwork,
                fileManager: fileManager
            ))

            // 5. Header Colors
            applyTrim(DiskCacheRetention.trim(
                at: storage.headerColorCacheURL,
                maxBytes: DiskCacheBudget.headerColors.maxBytes,
                targetFraction: DiskCacheBudget.headerColors.targetFraction,
                maxAge: DiskCacheBudget.headerColors.maxAge,
                fileManager: fileManager
            ))

            // 6. Stale import staging
            _ = await cleanupStaleImportStaging(
                roots: [storage.importStagingRootURL],
                reason: "periodicMaintenance",
                maxAge: staleImportStagingAge
            )

            if removedFiles > 0 {
                Log.info(
                    "[CacheManager] Disk maintenance completed: removed \(removedFiles) files, freed \(ByteCountFormatter.string(fromByteCount: removedBytes, countStyle: .file))",
                    category: .perf
                )
            }

            return DiskCacheTrimResult(
                removedFileCount: removedFiles,
                removedBytes: removedBytes
            )
        }.value
    }

    @MainActor private static var maintainedLibraryRoots: Set<URL> = []

    /// Schedules a non-blocking background disk cache maintenance pass shortly after launch.
    @MainActor
    static func scheduleBackgroundDiskMaintenance(storage: LibraryStorageLocations) {
        guard !maintainedLibraryRoots.contains(storage.libraryRootURL) else { return }
        maintainedLibraryRoots.insert(storage.libraryRootURL)
        Task {
            do {
                try await Task.sleep(nanoseconds: 12_000_000_000)
            } catch {
                return
            }
            _ = await trimAllDiskCaches(storage: storage)
        }
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
            locations.homeCacheURL,
            locations.libraryScanCacheRootURL,
            locations.sourceScanCacheRootURL,
        ]
    }

    private static func legacyCacheDirectories(
        at locations: LegacyLibraryStorageLocations
    ) -> [URL] {
        [
            locations.legacyIndexRootURL,
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
