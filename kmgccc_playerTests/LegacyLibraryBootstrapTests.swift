import Foundation
import XCTest
@testable import kmgccc_player

final class LegacyLibraryBootstrapTests: XCTestCase {
    func testRegistersExistingLibraryInPlaceAsManaged() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let bootstrap = makeBootstrap(registryURL: fixture.registry)

        let result = try bootstrap.run(
            legacyRootURL: fixture.root,
            generation: 42,
            now: Date(timeIntervalSince1970: 100)
        )

        let context = try XCTUnwrap(result.context)
        XCTAssertTrue(result.didCreateManifest)
        XCTAssertTrue(result.didRegisterLibrary)
        XCTAssertEqual(context.mode, .managed)
        XCTAssertEqual(context.generation, 42)
        XCTAssertEqual(context.rootURL, fixture.root.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Tracks").path))

        let manifest = try MusicLibraryManifest.read(from: context.paths.manifestURL)
        XCTAssertEqual(manifest.libraryID, context.id)
        XCTAssertEqual(manifest.mode, .managed)
        let registry = try MusicLibraryRegistryFile.load(from: fixture.registry)
        XCTAssertEqual(registry.activeLibraryID, context.id)
        XCTAssertEqual(registry.recentManagedLibraryID, context.id)
        XCTAssertEqual(registry.libraries.count, 1)
        let journal = try XCTUnwrap(LibraryUpgradeJournal.read(from: context.paths.upgradeJournalURL))
        XCTAssertEqual(journal.stage, .registryWritten)
        XCTAssertTrue(result.requiresPostRegistrationMigration)
    }

    func testRegistryWithoutActiveLibraryFallsBackToLegacyDiscovery() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let bootstrap = makeBootstrap(registryURL: fixture.registry)
        let first = try bootstrap.run(legacyRootURL: fixture.root)
        let libraryID = try XCTUnwrap(first.context?.id)

        // Simulate cleared settings: the registry survives but nothing is
        // active. Legacy discovery must adopt the default root again.
        var registry = try MusicLibraryRegistryFile.load(from: fixture.registry)
        registry.activeLibraryID = nil
        try MusicLibraryRegistryFile.save(registry, to: fixture.registry)

        let second = try bootstrap.run(legacyRootURL: fixture.root)
        XCTAssertEqual(second.context?.id, libraryID)
        XCTAssertFalse(second.didCreateManifest)
        XCTAssertEqual(try MusicLibraryRegistryFile.load(from: fixture.registry).activeLibraryID, libraryID)
    }

    func testBootstrapIsIdempotent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Playlists", isDirectory: true),
            withIntermediateDirectories: true
        )
        let bootstrap = makeBootstrap(registryURL: fixture.registry)

        let first = try bootstrap.run(legacyRootURL: fixture.root)
        let second = try bootstrap.run(legacyRootURL: fixture.root)

        XCTAssertEqual(first.context?.id, second.context?.id)
        XCTAssertFalse(second.didCreateManifest)
        XCTAssertFalse(second.didRegisterLibrary)
        XCTAssertTrue(second.requiresPostRegistrationMigration)
        XCTAssertEqual(try MusicLibraryRegistryFile.load(from: fixture.registry).libraries.count, 1)
    }

    func testResumesUsingIdentityPersistedInJournal() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let paths = LibraryPaths(rootURL: fixture.root)
        try FileManager.default.createDirectory(at: paths.tracksRootURL, withIntermediateDirectories: true)
        let expectedID = UUID()
        try LibraryUpgradeJournal(
            libraryID: expectedID,
            rootURL: fixture.root,
            stage: .discovered
        ).write(to: paths.upgradeJournalURL)

        let result = try makeBootstrap(registryURL: fixture.registry).run(legacyRootURL: fixture.root)

        XCTAssertEqual(result.context?.id, expectedID)
        XCTAssertEqual(try MusicLibraryManifest.read(from: paths.manifestURL).libraryID, expectedID)
    }

    func testDoesNotCreateLibraryForEmptyOrMissingRoot() throws {
        let fixture = try makeFixture(createRoot: false)
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let result = try makeBootstrap(registryURL: fixture.registry).run(legacyRootURL: fixture.root)

        XCTAssertEqual(result, .noLibrary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.registry.path))
    }

    func testCorruptedRegistryIsPreservedForRecovery() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let original = Data("corrupted-registry".utf8)
        try FileManager.default.createDirectory(
            at: fixture.registry.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try original.write(to: fixture.registry)

        XCTAssertThrowsError(
            try makeBootstrap(registryURL: fixture.registry).run(legacyRootURL: fixture.root)
        )
        XCTAssertEqual(try Data(contentsOf: fixture.registry), original)
        XCTAssertNil(
            try LibraryUpgradeJournal.read(
                from: LibraryPaths(rootURL: fixture.root).upgradeJournalURL
            )
        )
    }

    func testStaleBookmarkRefreshesRegistryAfterValidatedLastKnownFallback() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let initial = try makeBootstrap(registryURL: fixture.registry).run(
            legacyRootURL: fixture.root
        )
        let libraryID = try XCTUnwrap(initial.context?.id)
        let missingBookmarkRoot = fixture.container.appendingPathComponent("Missing", isDirectory: true)
        let refreshedData = Data("refreshed-bookmark".utf8)
        let bootstrap = LegacyLibraryBootstrap(
            registryURL: fixture.registry,
            bookmarkDataProvider: { _ in refreshedData },
            bookmarkURLResolver: { _ in (missingBookmarkRoot, true) }
        )

        let restored = try bootstrap.run(legacyRootURL: fixture.root)
        XCTAssertEqual(restored.context?.id, libraryID)
        XCTAssertEqual(restored.context?.rootURL.standardizedFileURL, fixture.root.standardizedFileURL)
        XCTAssertEqual(restored.context?.rootBookmarkData, refreshedData)
        let registry = try MusicLibraryRegistryFile.load(from: fixture.registry)
        XCTAssertEqual(registry.library(id: libraryID)?.rootBookmarkData, refreshedData)
        XCTAssertEqual(registry.library(id: libraryID)?.lastKnownPath, fixture.root.standardizedFileURL.path)
    }

    func testLastKnownFallbackRejectsManifestIdentityMismatch() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = try makeBootstrap(registryURL: fixture.registry).run(legacyRootURL: fixture.root)
        var manifest = try MusicLibraryManifest.read(
            from: LibraryPaths(rootURL: fixture.root).manifestURL
        )
        manifest = MusicLibraryManifest(
            libraryID: UUID(),
            displayName: manifest.displayName,
            mode: manifest.mode,
            createdAt: manifest.createdAt,
            updatedAt: manifest.updatedAt
        )
        try manifest.write(to: LibraryPaths(rootURL: fixture.root).manifestURL)
        let missingBookmarkRoot = fixture.container.appendingPathComponent("Missing", isDirectory: true)
        let bootstrap = LegacyLibraryBootstrap(
            registryURL: fixture.registry,
            bookmarkDataProvider: { _ in Data("unused".utf8) },
            bookmarkURLResolver: { _ in (missingBookmarkRoot, true) }
        )

        XCTAssertThrowsError(try bootstrap.run(legacyRootURL: fixture.root))
    }

    func testSchemaOneCommittedJournalResumesAtRegistryCheckpoint() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let paths = LibraryPaths(rootURL: fixture.root)
        let original = LibraryUpgradeJournal(
            libraryID: UUID(),
            rootURL: fixture.root,
            stage: .committed
        )
        try original.write(to: paths.upgradeJournalURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: paths.upgradeJournalURL)
            ) as? [String: Any]
        )
        object["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: object).write(
            to: paths.upgradeJournalURL,
            options: .atomic
        )

        let resumed = try XCTUnwrap(
            LibraryUpgradeJournal.read(from: paths.upgradeJournalURL)
        )

        XCTAssertEqual(resumed.schemaVersion, LibraryUpgradeJournal.schemaVersion)
        XCTAssertEqual(resumed.stage, .registryWritten)
    }

    func testCommittedCustomRootRestoresFromRegistryWithoutLegacyPathFallback() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let bootstrap = makeBootstrap(registryURL: fixture.registry)
        let first = try bootstrap.run(legacyRootURL: fixture.root)
        let context = try XCTUnwrap(first.context)
        var journal = try XCTUnwrap(
            LibraryUpgradeJournal.read(from: context.paths.upgradeJournalURL)
        )
        journal = journal.advancing(to: .committed)
        try journal.write(to: context.paths.upgradeJournalURL)
        let unrelatedFallback = fixture.container.appendingPathComponent(
            "Default Music/Library",
            isDirectory: true
        )

        let restored = try bootstrap.run(legacyRootURL: unrelatedFallback)

        XCTAssertEqual(restored.context?.id, context.id)
        XCTAssertEqual(restored.context?.rootURL, fixture.root.standardizedFileURL)
        XCTAssertFalse(restored.requiresPostRegistrationMigration)
    }

    @MainActor
    func testPostRegistrationUpgradeMigratesCachesValidatesThenCommits() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(
            try makeBootstrap(registryURL: fixture.registry)
                .run(legacyRootURL: fixture.root).context
        )
        let appContext = makeAppContext(from: context)
        let defaultsName = "LegacyLibraryBootstrapTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(fixture.root.path, forKey: "kmgccc_player.libraryRootPath")
        let legacy = makeLegacyStorageLocations(container: fixture.container)
        let oldHomeFile = legacy.legacyHomeURL.appendingPathComponent("snapshot.json")
        try FileManager.default.createDirectory(
            at: oldHomeFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("home-cache".utf8).write(to: oldHomeFile)
        let storage = kmgccc_player.StorageLocations.scoped(to: appContext.paths)
        let preservedDestination = storage.qqMusicCoverCacheURL
            .appendingPathComponent("preserved.jpg")
        try FileManager.default.createDirectory(
            at: preservedDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("new-cache".utf8).write(to: preservedDestination)
        let oldQQFile = legacy.legacyQQMusicCoverURL.appendingPathComponent("old.jpg")
        try FileManager.default.createDirectory(
            at: oldQQFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old-cache".utf8).write(to: oldQQFile)
        let legacyOverridesData = Data("{\"manual\":{\"title\":\"Edited\",\"updatedAt\":\"2026-07-30T00:00:00Z\"}}".utf8)
        let legacyRecordsData = Data("{ }".utf8)
        defaults.set(
            legacyOverridesData,
            forKey: "externalPlayback.matchOverrides.v1"
        )
        defaults.set(
            legacyRecordsData,
            forKey: "externalPlayback.cacheRecords.v1"
        )
        let preservedRecordsURL = storage.externalPlaybackMetadataURL
            .appendingPathComponent("records.json")
        try FileManager.default.createDirectory(
            at: preservedRecordsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let preservedRecordsData = Data("{\n}".utf8)
        try preservedRecordsData.write(to: preservedRecordsURL)
        try writeLegacyIndexes(at: legacy)
        var validationCount = 0
        let coordinator = kmgccc_player.LegacyLibraryUpgradeCoordinator(
            context: appContext,
            storageLocations: storage,
            defaults: defaults,
            legacyLocations: legacy
        ) {
            validationCount += 1
        }

        let outcome = await coordinator.runIfNeeded()
        let repeated = await coordinator.runIfNeeded()

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(repeated, .notNeeded)
        XCTAssertEqual(validationCount, 1)
        XCTAssertEqual(
            try Data(contentsOf: storage.homeCacheURL.appendingPathComponent("snapshot.json")),
            Data("home-cache".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: preservedDestination), Data("new-cache".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: storage.externalPlaybackMetadataURL
                .appendingPathComponent("overrides.json").path
        ))
        XCTAssertEqual(try Data(contentsOf: preservedRecordsURL), preservedRecordsData)
        XCTAssertEqual(
            defaults.data(forKey: "externalPlayback.matchOverrides.v1"),
            legacyOverridesData
        )
        XCTAssertNil(defaults.data(forKey: "externalPlayback.cacheRecords.v1"))
        XCTAssertTrue(legacy.legacyTrackIndexURLs.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        XCTAssertFalse(LibraryLocationStore.hasLegacyLibraryRoot(defaults: defaults))
        XCTAssertEqual(
            try LibraryUpgradeJournal.read(from: context.paths.upgradeJournalURL)?.stage,
            .committed
        )
    }

    @MainActor
    func testExternalPlaybackManualOverridesAreGlobalAndAutomaticRecordsAreLibraryScoped() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let firstRoot = fixture.container.appendingPathComponent("First Library", isDirectory: true)
        let secondRoot = fixture.container.appendingPathComponent("Second Library", isDirectory: true)
        let firstStorage = kmgccc_player.StorageLocations.scoped(
            to: kmgccc_player.LibraryPaths(rootURL: firstRoot)
        )
        let secondStorage = kmgccc_player.StorageLocations.scoped(
            to: kmgccc_player.LibraryPaths(rootURL: secondRoot)
        )
        let defaultsName = "LegacyLibraryBootstrapTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let raw = kmgccc_player.ExternalPlaybackRawMetadata(
            source: .appleMusic,
            title: "Original",
            artist: "Artist",
            duration: 180
        )
        let firstStore = kmgccc_player.ExternalPlaybackMetadataStore(
            storage: firstStorage,
            defaults: defaults
        )
        firstStore.saveOverride(
            kmgccc_player.ExternalPlaybackMatchOverride(
                title: "Edited",
                artist: nil,
                album: nil,
                manuallySelectedLyrics: nil,
                manuallySelectedLyricsSource: nil,
                lyricsTimeOffsetMs: nil,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            for: raw.stableKey
        )
        firstStore.saveManualLyrics("manual lyrics", source: "manual", for: raw.stableKey)
        _ = await firstStore.resolve(raw: raw, libraryTracks: [])

        let secondStore = kmgccc_player.ExternalPlaybackMetadataStore(
            storage: secondStorage,
            defaults: defaults
        )

        XCTAssertEqual(secondStore.effectiveMetadata(for: raw).title, "Edited")
        XCTAssertEqual(secondStore.manualLyrics(for: raw.stableKey), "manual lyrics")
        XCTAssertEqual(
            firstStorage.externalPlaybackMetadataURL,
            firstRoot.appendingPathComponent("Cache/ExternalPlayback", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: firstStorage.externalPlaybackMetadataURL
                .appendingPathComponent("records.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: secondStorage.externalPlaybackMetadataURL
                .appendingPathComponent("records.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: firstRoot.appendingPathComponent("ExternalPlayback").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: secondRoot.appendingPathComponent("ExternalPlayback").path
        ))
    }

    @MainActor
    func testCorruptLegacyExternalPlaybackRecordsRemainPendingAndRetry() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(
            try makeBootstrap(registryURL: fixture.registry)
                .run(legacyRootURL: fixture.root).context
        )
        let appContext = makeAppContext(from: context)
        let storage = kmgccc_player.StorageLocations.scoped(to: appContext.paths)
        let defaultsName = "LegacyLibraryBootstrapTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(fixture.root.path, forKey: "kmgccc_player.libraryRootPath")
        let corruptRecords = Data("not-json".utf8)
        defaults.set(corruptRecords, forKey: "externalPlayback.cacheRecords.v1")
        let legacy = makeLegacyStorageLocations(container: fixture.container)
        try writeLegacyIndexes(at: legacy)
        let coordinator = kmgccc_player.LegacyLibraryUpgradeCoordinator(
            context: appContext,
            storageLocations: storage,
            defaults: defaults,
            legacyLocations: legacy
        ) {}

        let pendingOutcome = await coordinator.runIfNeeded()
        XCTAssertEqual(pendingOutcome, .pending)
        XCTAssertEqual(
            defaults.data(forKey: "externalPlayback.cacheRecords.v1"),
            corruptRecords
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: storage.externalPlaybackMetadataURL
                .appendingPathComponent("records.json").path
        ))
        XCTAssertEqual(
            try LibraryUpgradeJournal.read(from: context.paths.upgradeJournalURL)?.stage,
            .registryWritten
        )

        let repairedRecords = Data("{}".utf8)
        defaults.set(repairedRecords, forKey: "externalPlayback.cacheRecords.v1")

        let completedOutcome = await coordinator.runIfNeeded()
        XCTAssertEqual(completedOutcome, .completed)
        XCTAssertEqual(
            try Data(
                contentsOf: storage.externalPlaybackMetadataURL
                    .appendingPathComponent("records.json")
            ),
            repairedRecords
        )
        XCTAssertNil(defaults.data(forKey: "externalPlayback.cacheRecords.v1"))
    }

    @MainActor
    func testCorruptExistingExternalPlaybackRecordsRemainPendingWithoutOverwrite() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(
            try makeBootstrap(registryURL: fixture.registry)
                .run(legacyRootURL: fixture.root).context
        )
        let appContext = makeAppContext(from: context)
        let storage = kmgccc_player.StorageLocations.scoped(to: appContext.paths)
        let defaultsName = "LegacyLibraryBootstrapTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(fixture.root.path, forKey: "kmgccc_player.libraryRootPath")
        let legacyRecords = Data("{}".utf8)
        defaults.set(legacyRecords, forKey: "externalPlayback.cacheRecords.v1")
        let destination = storage.externalPlaybackMetadataURL
            .appendingPathComponent("records.json")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corruptDestination = Data("broken-target".utf8)
        try corruptDestination.write(to: destination)
        let legacy = makeLegacyStorageLocations(container: fixture.container)
        try writeLegacyIndexes(at: legacy)
        let coordinator = kmgccc_player.LegacyLibraryUpgradeCoordinator(
            context: appContext,
            storageLocations: storage,
            defaults: defaults,
            legacyLocations: legacy
        ) {}

        let pendingOutcome = await coordinator.runIfNeeded()
        XCTAssertEqual(pendingOutcome, .pending)
        XCTAssertEqual(try Data(contentsOf: destination), corruptDestination)
        XCTAssertEqual(
            defaults.data(forKey: "externalPlayback.cacheRecords.v1"),
            legacyRecords
        )

        try Data("{ }".utf8).write(to: destination, options: .atomic)

        let completedOutcome = await coordinator.runIfNeeded()
        XCTAssertEqual(completedOutcome, .completed)
        XCTAssertEqual(try Data(contentsOf: destination), Data("{ }".utf8))
        XCTAssertNil(defaults.data(forKey: "externalPlayback.cacheRecords.v1"))
    }

    @MainActor
    func testFailedValidationKeepsLegacyAuthorityAndRetryCompletes() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(
            try makeBootstrap(registryURL: fixture.registry)
                .run(legacyRootURL: fixture.root).context
        )
        let appContext = makeAppContext(from: context)
        let defaultsName = "LegacyLibraryBootstrapTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(fixture.root.path, forKey: "kmgccc_player.libraryRootPath")
        let legacy = makeLegacyStorageLocations(container: fixture.container)
        try writeLegacyIndexes(at: legacy)
        let failing = kmgccc_player.LegacyLibraryUpgradeCoordinator(
            context: appContext,
            storageLocations: kmgccc_player.StorageLocations.scoped(to: appContext.paths),
            defaults: defaults,
            legacyLocations: legacy
        ) {
            throw kmgccc_player.LibraryUpgradeValidationError.damagedTrackSidecar
        }

        let failedOutcome = await failing.runIfNeeded()
        XCTAssertEqual(failedOutcome, .pending)
        XCTAssertTrue(LibraryLocationStore.hasLegacyLibraryRoot(defaults: defaults))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: legacy.legacyTrackIndexURLs[0].path
        ))
        XCTAssertEqual(
            try LibraryUpgradeJournal.read(from: context.paths.upgradeJournalURL)?.stage,
            .cachesMigrated
        )

        let retry = kmgccc_player.LegacyLibraryUpgradeCoordinator(
            context: appContext,
            storageLocations: kmgccc_player.StorageLocations.scoped(to: appContext.paths),
            defaults: defaults,
            legacyLocations: legacy
        ) {}
        let retryOutcome = await retry.runIfNeeded()
        XCTAssertEqual(retryOutcome, .completed)
        XCTAssertFalse(LibraryLocationStore.hasLegacyLibraryRoot(defaults: defaults))
    }

    func testStrictUpgradeDiskInspectionRejectsCorruptTrackSidecar() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(
            try makeBootstrap(registryURL: fixture.registry)
                .run(legacyRootURL: fixture.root).context
        )
        let package = context.paths.trackFolderURL(for: UUID())
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: package.appendingPathComponent("meta.json"))

        let appContext = makeAppContext(from: context)
        XCTAssertThrowsError(
            try kmgccc_player.LibraryUpgradeSessionValidator.inspectDisk(context: appContext)
        ) {
            XCTAssertEqual(
                $0 as? kmgccc_player.LibraryUpgradeValidationError,
                kmgccc_player.LibraryUpgradeValidationError.damagedTrackSidecar
            )
        }
        XCTAssertEqual(
            try LibraryUpgradeJournal.read(from: context.paths.upgradeJournalURL)?.stage,
            .registryWritten
        )
    }

    func testRegisteredLibraryOpensWithCorruptAdvisoryJournal() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let bootstrap = makeBootstrap(registryURL: fixture.registry)
        let initial = try bootstrap.run(legacyRootURL: fixture.root)
        let expectedID = try XCTUnwrap(initial.context?.id)
        let journalURL = LibraryPaths(rootURL: fixture.root).upgradeJournalURL
        let corruptJournal = Data("not-a-journal".utf8)
        try corruptJournal.write(to: journalURL, options: .atomic)

        let restored = try bootstrap.run(
            legacyRootURL: fixture.container.appendingPathComponent("Unrelated")
        )

        XCTAssertEqual(restored.context?.id, expectedID)
        XCTAssertTrue(restored.requiresPostRegistrationMigration)
        XCTAssertEqual(try Data(contentsOf: journalURL), corruptJournal)
    }

    @MainActor
    func testStoragePreparationMergesLegacyCacheIntoPrecreatedDestination() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(
            try makeBootstrap(registryURL: fixture.registry)
                .run(legacyRootURL: fixture.root).context
        )
        let appContext = makeAppContext(from: context)
        try appContext.paths.createRequiredDirectories()
        let storage = kmgccc_player.StorageLocations.scoped(to: appContext.paths)
        let legacy = makeLegacyStorageLocations(container: fixture.container)
        let legacyOnly = legacy.legacyHomeURL.appendingPathComponent("Nested/legacy.json")
        let legacyConflict = legacy.legacyHomeURL.appendingPathComponent("snapshot.json")
        try FileManager.default.createDirectory(
            at: legacyOnly.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy-only".utf8).write(to: legacyOnly)
        try Data("legacy-value".utf8).write(to: legacyConflict)
        let currentOnly = storage.homeCacheURL.appendingPathComponent("current.json")
        let currentConflict = storage.homeCacheURL.appendingPathComponent("snapshot.json")
        try Data("current-only".utf8).write(to: currentOnly)
        try Data("current-value".utf8).write(to: currentConflict)
        let defaultsName = "LegacyLibraryBootstrapTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(fixture.root.path, forKey: "kmgccc_player.libraryRootPath")

        let outcome = await kmgccc_player.LegacyLibraryUpgradeCoordinator
            .prepareStorageIfNeeded(
                context: appContext,
                storageLocations: storage,
                defaults: defaults,
                legacyLocations: legacy
            )

        XCTAssertEqual(outcome, .prepared)
        XCTAssertEqual(
            try Data(contentsOf: storage.homeCacheURL.appendingPathComponent("Nested/legacy.json")),
            Data("legacy-only".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: currentOnly), Data("current-only".utf8))
        XCTAssertEqual(try Data(contentsOf: currentConflict), Data("current-value".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyOnly.path))
        XCTAssertEqual(
            try LibraryUpgradeJournal.read(from: context.paths.upgradeJournalURL)?.stage,
            .cachesMigrated
        )
    }

    @MainActor
    func testStoragePreparationCopiesReadableLegacyPlaybackHistoryBeforeStoreOpens() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(
            try makeBootstrap(registryURL: fixture.registry)
                .run(legacyRootURL: fixture.root).context
        )
        let appContext = makeAppContext(from: context)
        let legacy = makeLegacyStorageLocations(container: fixture.container)
        let legacyRoot = legacy.legacyPlaybackHistoryStoreURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        createLegacyHistoryStore(at: legacyRoot)
        let defaultsName = "LegacyLibraryBootstrapTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(fixture.root.path, forKey: "kmgccc_player.libraryRootPath")

        let outcome = await kmgccc_player.LegacyLibraryUpgradeCoordinator
            .prepareStorageIfNeeded(
                context: appContext,
                storageLocations: kmgccc_player.StorageLocations.scoped(to: appContext.paths),
                defaults: defaults,
                legacyLocations: legacy
            )
        let migratedStore = kmgccc_player.PlaybackHistoryStore(context: appContext)

        XCTAssertEqual(outcome, .prepared)
        XCTAssertEqual(migratedStore.fetchItems().map(\.title), ["Legacy Song"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: legacy.legacyPlaybackHistoryStoreURL.path
        ))
    }

    @MainActor
    func testStoragePreparationRejectsCorruptLegacyPlaybackHistory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(
            try makeBootstrap(registryURL: fixture.registry)
                .run(legacyRootURL: fixture.root).context
        )
        let appContext = makeAppContext(from: context)
        let legacy = makeLegacyStorageLocations(container: fixture.container)
        try FileManager.default.createDirectory(
            at: legacy.legacyPlaybackHistoryStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corruptStore = Data("not-sqlite".utf8)
        try corruptStore.write(to: legacy.legacyPlaybackHistoryStoreURL)
        let defaultsName = "LegacyLibraryBootstrapTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(fixture.root.path, forKey: "kmgccc_player.libraryRootPath")

        let outcome = await kmgccc_player.LegacyLibraryUpgradeCoordinator
            .prepareStorageIfNeeded(
                context: appContext,
                storageLocations: kmgccc_player.StorageLocations.scoped(to: appContext.paths),
                defaults: defaults,
                legacyLocations: legacy
            )

        XCTAssertEqual(outcome, .pending)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: appContext.paths.playbackHistoryStoreURL.path
        ))
        XCTAssertEqual(
            try Data(contentsOf: legacy.legacyPlaybackHistoryStoreURL),
            corruptStore
        )
        XCTAssertEqual(
            try LibraryUpgradeJournal.read(from: context.paths.upgradeJournalURL)?.stage,
            .registryWritten
        )
    }

    func testStrictUpgradeDiskInspectionRejectsUnreadablePlaylistDirectory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(
            try makeBootstrap(registryURL: fixture.registry)
                .run(legacyRootURL: fixture.root).context
        )
        try Data("not-a-directory".utf8).write(to: context.paths.playlistsRootURL)

        XCTAssertThrowsError(
            try kmgccc_player.LibraryUpgradeSessionValidator.inspectDisk(
                context: makeAppContext(from: context)
            )
        ) {
            XCTAssertEqual(
                $0 as? kmgccc_player.LibraryUpgradeValidationError,
                .damagedPlaylistSidecar
            )
        }
    }

    private func makeBootstrap(registryURL: URL) -> LegacyLibraryBootstrap {
        LegacyLibraryBootstrap(
            registryURL: registryURL,
            bookmarkDataProvider: { Data("bookmark:\($0.path)".utf8) },
            bookmarkURLResolver: { data in
                let raw = String(decoding: data, as: UTF8.self)
                guard raw.hasPrefix("bookmark:") else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return (
                    URL(
                        fileURLWithPath: String(raw.dropFirst("bookmark:".count)),
                        isDirectory: true
                    ),
                    false
                )
            }
        )
    }

    private func makeLegacyStorageLocations(
        container: URL
    ) -> kmgccc_player.LegacyLibraryStorageLocations {
        kmgccc_player.LegacyLibraryStorageLocations(
            applicationSupportRootURL: container.appendingPathComponent(
                "LegacyApplicationSupport",
                isDirectory: true
            ),
            cachesRootURL: container.appendingPathComponent(
                "LegacyCaches",
                isDirectory: true
            ),
            bundleIdentifier: "kmgccc.player.tests"
        )
    }

    private func writeLegacyIndexes(
        at locations: kmgccc_player.LegacyLibraryStorageLocations
    ) throws {
        for url in [locations.legacyTrackIndexURLs[0], locations.legacySearchIndexURLs[0]] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("legacy-index".utf8).write(to: url)
        }
    }

    @MainActor
    private func createLegacyHistoryStore(at rootURL: URL) {
        let context = kmgccc_player.LibraryContext(
            id: UUID(),
            mode: .managed,
            rootURL: rootURL,
            rootBookmarkData: Data(),
            generation: 1
        )
        let store = kmgccc_player.PlaybackHistoryStore(context: context)
        store.record(
            trackID: UUID(),
            playedAt: Date(timeIntervalSince1970: 100),
            title: "Legacy Song",
            artist: "Legacy Artist",
            album: "Legacy Album",
            duration: 180,
            playedSeconds: 120
        )
    }

    private func makeAppContext(
        from context: LibraryContext
    ) -> kmgccc_player.LibraryContext {
        kmgccc_player.LibraryContext(
            id: context.id,
            mode: kmgccc_player.MusicLibraryMode.managed,
            rootURL: context.rootURL,
            rootBookmarkData: context.rootBookmarkData,
            generation: context.generation
        )
    }

    private func makeFixture(createRoot: Bool = true) throws -> (
        container: URL,
        root: URL,
        registry: URL
    ) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgccc-bootstrap-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let parent = container.appendingPathComponent("Music", isDirectory: true)
        let root = parent.appendingPathComponent(LibraryPaths.rootDirectoryName, isDirectory: true)
        if createRoot {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return (
            container,
            root,
            container.appendingPathComponent("AppSupport/LibraryRegistry.json")
        )
    }
}
