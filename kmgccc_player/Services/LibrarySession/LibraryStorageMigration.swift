import Foundation
import SQLite3

nonisolated enum LegacyLibraryUpgradeOutcome: Sendable, Equatable {
    case notNeeded
    case completed
    case pending
}

nonisolated enum LegacyLibraryStoragePreparationOutcome: Sendable, Equatable {
    case notNeeded
    case prepared
    case pending
}

nonisolated enum LibraryUpgradeValidationError: Error, Equatable {
    case journalIdentityMismatch
    case journalNotRegistered
    case manifestMismatch
    case damagedTrackSidecar
    case damagedPlaylistSidecar
    case duplicateTrackID
    case trackCountMismatch
    case playlistReferenceMissing
    case storageModeMismatch
    case trackIndexUnavailable
    case trackIndexMismatch
    case searchIndexMismatch
    case historyStoreMismatch
    case sqliteIntegrityFailed(String)
    case legacyIndexCleanupFailed
}

nonisolated struct LegacyLibraryStorageLocations: Sendable, Equatable {
    let applicationSupportRootURL: URL
    let cachesRootURL: URL
    let bundleIdentifier: String

    init(
        applicationSupportRootURL: URL,
        cachesRootURL: URL,
        bundleIdentifier: String = "kmgccc.player"
    ) {
        self.applicationSupportRootURL = applicationSupportRootURL
        self.cachesRootURL = cachesRootURL
        self.bundleIdentifier = bundleIdentifier
    }

    static func system(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "kmgccc.player") -> Self {
        let fileManager = FileManager.default
        return Self(
            applicationSupportRootURL: fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
            cachesRootURL: fileManager.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory,
            bundleIdentifier: bundleIdentifier
        )
    }

    var legacyIndexRootURL: URL {
        applicationSupportRootURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("IndexCache", isDirectory: true)
    }

    var legacyPlaybackHistoryStoreURL: URL {
        applicationSupportRootURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("PlaybackHistory", isDirectory: true)
            .appendingPathComponent(PlaybackHistoryStorePaths.storeFileName)
    }

    var legacyTrackIndexURLs: [URL] {
        relatedSQLiteFiles(named: "TrackIndex.sqlite", in: legacyIndexRootURL)
    }

    var legacySearchIndexURLs: [URL] {
        relatedSQLiteFiles(named: "LibrarySearch.sqlite", in: legacyIndexRootURL)
    }

    var legacyAppCacheRootURL: URL {
        cachesRootURL.appendingPathComponent("kmgccc_player", isDirectory: true)
    }

    var legacyPlaylistArtworkURL: URL {
        legacyAppCacheRootURL.appendingPathComponent("PlaylistArtworkDerivatives", isDirectory: true)
    }

    var legacyQQMusicCoverURL: URL {
        legacyAppCacheRootURL.appendingPathComponent("QQMusicCoverCache", isDirectory: true)
    }

    var legacyExternalPlaybackArtworkURL: URL {
        legacyAppCacheRootURL.appendingPathComponent("ExternalPlaybackArtwork", isDirectory: true)
    }

    var legacyColorsURL: URL {
        legacyAppCacheRootURL.appendingPathComponent("Colors", isDirectory: true)
    }

    var legacyHomeURL: URL {
        legacyAppCacheRootURL.appendingPathComponent("Home", isDirectory: true)
    }

    var legacyAMLLDBURL: URL {
        cachesRootURL.appendingPathComponent("AMLLDB", isDirectory: true)
    }

    private func relatedSQLiteFiles(named fileName: String, in directory: URL) -> [URL] {
        let store = directory.appendingPathComponent(fileName)
        return [
            store,
            URL(fileURLWithPath: store.path + "-wal"),
            URL(fileURLWithPath: store.path + "-shm"),
        ]
    }
}

@MainActor
final class LegacyLibraryUpgradeCoordinator {
    typealias Validation = @MainActor () async throws -> Void

    private let context: LibraryContext
    private let storageLocations: LibraryStorageLocations
    private let defaults: UserDefaults
    private let legacyLocations: LegacyLibraryStorageLocations
    private let validation: Validation

    init(
        context: LibraryContext,
        storageLocations: LibraryStorageLocations,
        defaults: UserDefaults = .standard,
        legacyLocations: LegacyLibraryStorageLocations = .system(),
        validation: @escaping Validation
    ) {
        self.context = context
        self.storageLocations = storageLocations
        self.defaults = defaults
        self.legacyLocations = legacyLocations
        self.validation = validation
    }

    static func prepareStorageIfNeeded(
        context: LibraryContext,
        storageLocations: LibraryStorageLocations,
        defaults: UserDefaults = .standard,
        legacyLocations: LegacyLibraryStorageLocations = .system()
    ) async -> LegacyLibraryStoragePreparationOutcome {
        let checkpoint: LibraryUpgradeJournal?
        switch preparationEligibility(context: context, defaults: defaults) {
        case .notNeeded:
            return .notNeeded
        case .blocked:
            return .pending
        case .eligible(let journal):
            checkpoint = journal
        }

        var hasFailure = false
        do {
            try ExternalPlaybackMetadataStore.migrateLegacyPersistenceIfNeeded(
                to: storageLocations,
                stagingRootURL: context.paths.importStagingRootURL,
                defaults: defaults
            )
        } catch {
            hasFailure = true
            Log.warning(
                "[LibraryUpgrade] external playback metadata migration pending: \(error)",
                category: .library
            )
        }

        do {
            try PlaybackHistoryStorePaths.migrateLegacyStoreIfNeeded(
                to: context,
                legacyStoreURL: legacyLocations.legacyPlaybackHistoryStoreURL,
                upgradedLegacyRootURL: LibraryLocationStore.legacyLibraryRootURL(defaults: defaults),
                stagingRootURL: context.paths.importStagingRootURL,
                defaults: defaults
            )
        } catch {
            hasFailure = true
            Log.warning(
                "[LibraryUpgrade] playback history migration pending: \(error)",
                category: .library
            )
        }

        let cacheResult = await CacheManager.migrateLegacyCaches(
            to: storageLocations,
            stagingRootURL: context.paths.importStagingRootURL,
            legacyLocations: legacyLocations
        )
        if cacheResult.failedDirectories > 0 {
            hasFailure = true
            Log.warning(
                "[LibraryUpgrade] cache migration pending failures=\(cacheResult.failedDirectories)",
                category: .library
            )
        }
        guard !hasFailure else { return .pending }

        if let checkpoint, checkpoint.stage < .cachesMigrated {
            do {
                try checkpoint.advancing(to: .cachesMigrated).write(
                    to: context.paths.upgradeJournalURL
                )
            } catch {
                Log.warning(
                    "[LibraryUpgrade] pre-session storage checkpoint pending: \(error)",
                    category: .library
                )
                return .pending
            }
        }
        return .prepared
    }

    func runIfNeeded(now: Date = Date()) async -> LegacyLibraryUpgradeOutcome {
        let journal: LibraryUpgradeJournal
        do {
            guard let stored = try LibraryUpgradeJournal.read(from: context.paths.upgradeJournalURL)
            else {
                return .notNeeded
            }
            journal = stored
        } catch {
            Log.error("[LibraryUpgrade] journal read failed", category: .library)
            return .pending
        }

        guard journal.libraryID == context.id,
              journal.rootPath == context.rootURL.standardizedFileURL.path else {
            Log.error("[LibraryUpgrade] journal identity mismatch", category: .library)
            return .pending
        }
        if journal.stage == .committed {
            removeLegacyLocationKeyIfOwned()
            ExternalPlaybackMetadataStore.removeLegacyPersistence(defaults: defaults)
            await CacheManager.removeMigratedLegacyCaches(at: legacyLocations)
            await CacheManager.removeLegacyImportStaging(at: context.rootURL)
            return .notNeeded
        }
        guard journal.stage >= .registryWritten else {
            return .pending
        }

        var current = journal
        if current.stage < .cachesMigrated {
            let preparation = await Self.prepareStorageIfNeeded(
                context: context,
                storageLocations: storageLocations,
                defaults: defaults,
                legacyLocations: legacyLocations
            )
            guard preparation == .prepared else {
                return .pending
            }
            do {
                current = current.advancing(to: .cachesMigrated, now: now)
                try current.write(to: context.paths.upgradeJournalURL)
            } catch {
                Log.error("[LibraryUpgrade] cache checkpoint failed", category: .library)
                return .pending
            }
        }

        if current.stage < .validated {
            do {
                try await validation()
                current = current.advancing(to: .validated, now: now)
                try current.write(to: context.paths.upgradeJournalURL)
            } catch {
                Log.warning("[LibraryUpgrade] validation pending: \(error)", category: .library)
                return .pending
            }
        }

        let didRemoveLegacyIndexes = await CacheManager.removeLegacyIndexes(
            at: legacyLocations
        )
        guard didRemoveLegacyIndexes else {
            Log.warning("[LibraryUpgrade] legacy index cleanup pending", category: .library)
            return .pending
        }

        do {
            current = current.advancing(to: .committed, now: now)
            try current.write(to: context.paths.upgradeJournalURL)
        } catch {
            Log.error("[LibraryUpgrade] commit checkpoint failed", category: .library)
            return .pending
        }

        removeLegacyLocationKeyIfOwned()
        ExternalPlaybackMetadataStore.removeLegacyPersistence(defaults: defaults)
        await CacheManager.removeMigratedLegacyCaches(at: legacyLocations)
        await CacheManager.removeLegacyImportStaging(at: context.rootURL)
        return .completed
    }

    private func removeLegacyLocationKeyIfOwned() {
        guard LibraryLocationStore.hasLegacyLibraryRoot(defaults: defaults),
              LibraryLocationStore.legacyLibraryRootURL(defaults: defaults).standardizedFileURL
                == context.rootURL.standardizedFileURL else {
            return
        }
        LibraryLocationStore.removeLegacyLibraryRoot(defaults: defaults)
    }

    private enum PreparationEligibility {
        case notNeeded
        case eligible(LibraryUpgradeJournal?)
        case blocked
    }

    private static func preparationEligibility(
        context: LibraryContext,
        defaults: UserDefaults
    ) -> PreparationEligibility {
        let journalURL = context.paths.upgradeJournalURL
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            return .notNeeded
        }

        do {
            guard let journal = try LibraryUpgradeJournal.read(from: journalURL) else {
                return .notNeeded
            }
            guard journal.libraryID == context.id,
                  journal.rootPath == context.rootURL.standardizedFileURL.path,
                  journal.stage >= .registryWritten else {
                return .blocked
            }
            return journal.stage == .committed ? .notNeeded : .eligible(journal)
        } catch {
            // A registered library and its manifest remain authoritative when
            // the advisory checkpoint is damaged. Restrict best-effort
            // preparation to the legacy root so another library cannot claim
            // process-global legacy data.
            guard context.mode == .managed,
                  context.rootURL.standardizedFileURL
                    == LibraryLocationStore.legacyLibraryRootURL(defaults: defaults)
                        .standardizedFileURL else {
                return .blocked
            }
            Log.warning(
                "[LibraryUpgrade] damaged journal; preparing owned legacy storage without advancing it",
                category: .library
            )
            return .eligible(nil)
        }
    }
}

@MainActor
enum LibraryUpgradeSessionValidator {
    static func validate(
        context: LibraryContext,
        libraryViewModel: LibraryViewModel,
        repository: SwiftDataLibraryRepository,
        searchIndex: LibrarySearchIndex,
        playbackHistoryStore: PlaybackHistoryStore
    ) async throws {
        guard libraryViewModel.lastLoadingError == nil,
              libraryViewModel.state == .loaded else {
            throw LibraryUpgradeValidationError.trackCountMismatch
        }

        let disk = try await Task.detached(priority: .utility) {
            try inspectDisk(context: context)
        }.value
        let runtimeTracks = await repository.fetchTracks(in: nil)
        let runtimeTrackIDs = Set(runtimeTracks.map(\.id))
        guard runtimeTrackIDs == disk.trackIDs else {
            throw LibraryUpgradeValidationError.trackCountMismatch
        }
        guard disk.playlistTrackIDs.isSubset(of: disk.trackIDs) else {
            throw LibraryUpgradeValidationError.playlistReferenceMissing
        }
        guard disk.locatorKinds.allSatisfy({ $0 == context.mode.storageKind }) else {
            throw LibraryUpgradeValidationError.storageModeMismatch
        }
        guard try repository.persistedTrackIndexIDs() == disk.trackIDs else {
            throw LibraryUpgradeValidationError.trackIndexMismatch
        }

        await searchIndex.waitForPendingRebuild()
        try await searchIndex.validateIntegrity(expectedTrackIDs: disk.trackIDs)
        try playbackHistoryStore.validateReadableStore(at: context.paths.playbackHistoryStoreURL)

        let manifest = try MusicLibraryManifest.read(from: context.paths.manifestURL)
        guard manifest.libraryID == context.id, manifest.mode == context.mode else {
            throw LibraryUpgradeValidationError.manifestMismatch
        }
        for url in [
            context.paths.trackIndexStoreURL,
            context.paths.searchIndexStoreURL,
            context.paths.playbackHistoryStoreURL,
        ] {
            try await Task.detached(priority: .utility) {
                try validateSQLite(at: url)
            }.value
        }
    }

    nonisolated struct DiskSnapshot: Sendable {
        let trackIDs: Set<UUID>
        let playlistTrackIDs: Set<UUID>
        let locatorKinds: [LocalTrackStorageKind]
    }

    nonisolated static func inspectDisk(
        context: LibraryContext
    ) throws -> DiskSnapshot {
        let fileManager = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var trackIDs = Set<UUID>()
        var locatorKinds: [LocalTrackStorageKind] = []

        for directory in try directDirectories(at: context.paths.tracksRootURL) {
            guard let folderID = UUID(uuidString: directory.lastPathComponent) else {
                throw LibraryUpgradeValidationError.damagedTrackSidecar
            }
            let metaURL = directory.appendingPathComponent("meta.json")
            guard let sidecar = try? decoder.decode(
                TrackSidecar.self,
                from: Data(contentsOf: metaURL)
            ), sidecar.id == folderID else {
                throw LibraryUpgradeValidationError.damagedTrackSidecar
            }
            guard trackIDs.insert(sidecar.id).inserted else {
                throw LibraryUpgradeValidationError.duplicateTrackID
            }
            locatorKinds.append(sidecar.mediaLocator.storageKind)
        }

        var playlistTrackIDs = Set<UUID>()
        let playlistURLs: [URL]
        do {
            playlistURLs = try fileManager.contentsOfDirectory(
                at: context.paths.playlistsRootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw LibraryUpgradeValidationError.damagedPlaylistSidecar
        }
        for url in playlistURLs where url.pathExtension.lowercased() == "json" {
            guard let sidecar = try? decoder.decode(
                PlaylistSidecar.self,
                from: Data(contentsOf: url)
            ) else {
                throw LibraryUpgradeValidationError.damagedPlaylistSidecar
            }
            playlistTrackIDs.formUnion(sidecar.trackIDs)
        }

        return DiskSnapshot(
            trackIDs: trackIDs,
            playlistTrackIDs: playlistTrackIDs,
            locatorKinds: locatorKinds
        )
    }

    private nonisolated static func directDirectories(at rootURL: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
    }

    private nonisolated static func validateSQLite(at url: URL) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close_v2(database) }
            throw LibraryUpgradeValidationError.sqliteIntegrityFailed(url.lastPathComponent)
        }
        defer { sqlite3_close_v2(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LibraryUpgradeValidationError.sqliteIntegrityFailed(url.lastPathComponent)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0),
              String(cString: raw).lowercased() == "ok" else {
            throw LibraryUpgradeValidationError.sqliteIntegrityFailed(url.lastPathComponent)
        }
    }
}

private nonisolated extension MusicLibraryMode {
    var storageKind: LocalTrackStorageKind {
        switch self {
        case .managed: return .managed
        case .referenced: return .referenced
        }
    }
}
