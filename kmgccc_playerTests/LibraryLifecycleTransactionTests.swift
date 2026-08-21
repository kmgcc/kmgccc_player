import XCTest
@testable import kmgccc_player

@MainActor
final class LibraryLifecycleTransactionTests: XCTestCase {
    func testCreationBuildsFixedRootAndActivatesProductionTransaction() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = fixture.creationService()

        let result = try await service.create(
            mode: .managed,
            parentURL: fixture.root.appendingPathComponent("parent"),
            displayName: "Music"
        )
        guard case .created(let context, _) = result else { return XCTFail("Expected creation") }
        XCTAssertEqual(context.rootURL.lastPathComponent, LibraryPaths.rootDirectoryName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.paths.librarySettingsURL.path))
        XCTAssertEqual(fixture.controller.activeLibraryContext?.id, context.id)
        let registry = await fixture.registry.snapshot()
        XCTAssertEqual(registry.activeLibraryID, context.id)
    }

    func testCreationRejectsNonemptyInvalidDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("parent")
        let destination = parent.appendingPathComponent(LibraryPaths.rootDirectoryName)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: destination.appendingPathComponent("keep.txt"))

        await XCTAssertThrowsErrorAsync(
            try await fixture.creationService().create(mode: .managed, parentURL: parent, displayName: "Music")
        ) { XCTAssertEqual($0 as? LibraryCreationError, .destinationContainsUnknownItems) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("keep.txt").path))
    }

    func testCreationReturnsExistingAndModeMismatchWithoutOverwrite() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("parent")
        let existing = try await fixture.creationService().create(
            mode: .referenced,
            parentURL: parent,
            displayName: "Reference"
        )
        guard case .created(let original, _) = existing else { return XCTFail() }

        let result = try await fixture.creationService().create(
            mode: .managed,
            parentURL: parent,
            displayName: "Replacement"
        )
        guard case .existingLibraryModeMismatch(let opened, let requested) = result else { return XCTFail() }
        XCTAssertEqual(opened.id, original.id)
        XCTAssertEqual(requested, .managed)
        XCTAssertEqual(try MusicLibraryManifest.read(from: opened.paths.manifestURL).displayName, "Reference")
    }

    func testOpenDeduplicatesIDRefreshesMovedPathAndRejectsPathConflict() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let firstRoot = fixture.root.appendingPathComponent("first")
        let manifest = try fixture.makeLibrary(at: firstRoot, mode: .managed)
        let first = try await fixture.openService.open(selectedURL: firstRoot)
        XCTAssertTrue(first.didRegister)

        let movedParent = fixture.root.appendingPathComponent("moved-parent")
        try FileManager.default.createDirectory(at: movedParent, withIntermediateDirectories: true)
        let movedRoot = movedParent.appendingPathComponent(LibraryPaths.rootDirectoryName)
        try FileManager.default.copyItem(at: firstRoot, to: movedRoot)
        let moved = try await fixture.openService.open(selectedURL: movedParent)
        XCTAssertFalse(moved.didRegister)
        XCTAssertEqual(moved.context.id, manifest.libraryID)
        let movedRegistry = await fixture.registry.snapshot()
        XCTAssertEqual(movedRegistry.libraries.count, 1)

        let conflictManifest = kmgccc_player.MusicLibraryManifest(displayName: "Conflict", mode: .managed)
        let conflictDescriptor = try kmgccc_player.MusicLibraryBookmark.make(
            manifest: conflictManifest,
            rootURL: movedRoot,
            bookmarkData: fixture.bookmarks.refreshBookmark(for: movedRoot)
        )
        let registryURL = await fixture.registry.fileURL
        var corrupt = await fixture.registry.snapshot()
        corrupt.libraries = [conflictDescriptor]
        corrupt.activeLibraryID = nil
        corrupt.recentManagedLibraryID = nil
        corrupt.recentReferencedLibraryID = nil
        try kmgccc_player.MusicLibraryRegistryFile.save(corrupt, to: registryURL)
        _ = try await fixture.registry.reload()
        await XCTAssertThrowsErrorAsync(
            try await fixture.openService.open(selectedURL: movedRoot, activate: false)
        ) { XCTAssertEqual($0 as? LibraryOpenError, .pathConflict) }
    }

    func testOpenExplicitRecoveryReplacesStalePathDescriptorWithoutRemovingRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("recovered")
        let actual = try fixture.makeLibrary(at: root, mode: .managed, displayName: "Recovered")
        let stale = kmgccc_player.MusicLibraryManifest(displayName: "Stale", mode: .managed)
        try await fixture.registerWithoutActivation(root: root, manifest: stale)

        let opened = try await fixture.openService.open(
            selectedURL: root,
            allowStalePathConflictRepair: true
        )

        XCTAssertEqual(opened.context.id, actual.libraryID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        let registry = await fixture.registry.snapshot()
        XCTAssertNil(registry.library(id: stale.libraryID))
        XCTAssertEqual(registry.activeLibraryID, actual.libraryID)
    }

    func testReconnectRegisteredLibraryRejectsWrongIdentityAndModeWithoutMutation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let originalRoot = fixture.root.appendingPathComponent("original")
        let original = try fixture.makeLibrary(at: originalRoot, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: originalRoot)
        let registryBefore = await fixture.registry.snapshot()

        let foreignRoot = fixture.root.appendingPathComponent("foreign")
        let foreign = try fixture.makeLibrary(at: foreignRoot, mode: .managed)
        await XCTAssertThrowsErrorAsync(
            try await fixture.openService.reconnectRegisteredLibrary(
                id: original.libraryID,
                selectedURL: foreignRoot
            )
        ) {
            XCTAssertEqual(
                $0 as? LibraryOpenError,
                .reconnectIdentifierMismatch(
                    expected: original.libraryID,
                    actual: foreign.libraryID
                )
            )
        }
        let registryAfterIdentityMismatch = await fixture.registry.snapshot()
        XCTAssertEqual(registryAfterIdentityMismatch, registryBefore)
        XCTAssertEqual(fixture.controller.activeLibraryContext?.id, original.libraryID)

        let wrongModeRoot = fixture.root.appendingPathComponent("wrong-mode")
        let wrongMode = kmgccc_player.MusicLibraryManifest(
            libraryID: original.libraryID,
            displayName: "Wrong Mode",
            mode: .referenced
        )
        let wrongModePaths = kmgccc_player.LibraryPaths(rootURL: wrongModeRoot)
        try wrongModePaths.createRequiredDirectories()
        try wrongMode.write(to: wrongModePaths.manifestURL)
        try Data("{}".utf8).write(to: wrongModePaths.librarySettingsURL)

        await XCTAssertThrowsErrorAsync(
            try await fixture.openService.reconnectRegisteredLibrary(
                id: original.libraryID,
                selectedURL: wrongModeRoot
            )
        ) {
            XCTAssertEqual(
                $0 as? LibraryOpenError,
                .reconnectModeMismatch(expected: .managed, actual: .referenced)
            )
        }
        let registryAfterModeMismatch = await fixture.registry.snapshot()
        XCTAssertEqual(registryAfterModeMismatch, registryBefore)
        XCTAssertEqual(
            fixture.controller.activeLibraryContext?.rootURL.standardizedFileURL.path,
            originalRoot.standardizedFileURL.path
        )
    }

    func testActiveRelocationCopiesValidatesLoadsThenUpdatesRegistry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        let manifest = try fixture.makeLibrary(at: source, mode: .managed)
        let opened = try await fixture.openService.open(selectedURL: source)
        let destinationParent = fixture.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        let result = try await fixture.relocationService().relocate(
            libraryID: manifest.libraryID,
            toParent: destinationParent
        )
        guard case .moved(let context, _) = result else { return XCTFail() }
        XCTAssertNotEqual(context.rootURL, opened.context.rootURL)
        XCTAssertEqual(fixture.controller.activeLibraryContext?.rootURL, context.rootURL)
        let registry = await fixture.registry.snapshot()
        XCTAssertEqual(registry.library(id: manifest.libraryID)?.lastKnownPath, context.rootURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testNonactiveRelocationRestoresOriginalActiveLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let activeRoot = fixture.root.appendingPathComponent("active")
        let active = try fixture.makeLibrary(at: activeRoot, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: activeRoot)
        let source = fixture.root.appendingPathComponent("source")
        let moved = try fixture.makeLibrary(at: source, mode: .referenced)
        try await fixture.registerWithoutActivation(root: source, manifest: moved)
        let parent = fixture.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        _ = try await fixture.relocationService().relocate(libraryID: moved.libraryID, toParent: parent)
        XCTAssertEqual(fixture.controller.activeLibraryContext?.id, active.libraryID)
        let registry = await fixture.registry.snapshot()
        XCTAssertEqual(
            registry.library(id: moved.libraryID)?.lastKnownPath,
            parent.appendingPathComponent(LibraryPaths.rootDirectoryName).path
        )
    }

    func testRelocationLoadFailureRemovesDestinationAndRestoresOldSessionRegistry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        let manifest = try fixture.makeLibrary(at: source, mode: .managed)
        let opened = try await fixture.openService.open(selectedURL: source)
        fixture.factory.failNextLoadForNewRoot = true
        let parent = fixture.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        await XCTAssertThrowsErrorAsync(
            try await fixture.relocationService().relocate(libraryID: manifest.libraryID, toParent: parent)
        ) { XCTAssertEqual($0 as? LibraryRelocationError, .newSessionFailed) }
        XCTAssertEqual(fixture.controller.activeLibraryContext?.rootURL, opened.context.rootURL)
        let registry = await fixture.registry.snapshot()
        XCTAssertEqual(registry.library(id: manifest.libraryID)?.lastKnownPath, source.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(LibraryPaths.rootDirectoryName).path))
    }

    func testRelocationRecycleFailureIsTypedPartialSuccess() async throws {
        let fixture = try Fixture(recyclerFails: true)
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        let manifest = try fixture.makeLibrary(at: source, mode: .referenced)
        _ = try await fixture.openService.open(selectedURL: source)
        let parent = fixture.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let result = try await fixture.relocationService().relocate(libraryID: manifest.libraryID, toParent: parent)
        guard case .moved(_, transfer: .sameVolume) = result else { return XCTFail() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testActiveRemovalRecycleFailureRestoresSessionAndRegistry() async throws {
        let fixture = try Fixture(recyclerFails: true)
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        let manifest = try fixture.makeLibrary(at: source, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: source)

        await XCTAssertThrowsErrorAsync(
            try await fixture.removalService().moveToTrash(libraryID: manifest.libraryID)
        ) { XCTAssertEqual($0 as? LibraryRemovalError, .recycleFailed) }
        XCTAssertEqual(fixture.controller.activeLibraryContext?.id, manifest.libraryID)
        let registry = await fixture.registry.snapshot()
        XCTAssertNotNil(registry.library(id: manifest.libraryID))
    }

    func testNonactiveReferencedRemovalPreservesExternalAudio() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let activeRoot = fixture.root.appendingPathComponent("active")
        _ = try fixture.makeLibrary(at: activeRoot, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: activeRoot)
        let referencedRoot = fixture.root.appendingPathComponent("referenced")
        let referenced = try fixture.makeLibrary(at: referencedRoot, mode: .referenced)
        try await fixture.registerWithoutActivation(root: referencedRoot, manifest: referenced)
        let external = fixture.root.appendingPathComponent("external.wav")
        try Data("audio".utf8).write(to: external)

        _ = try await fixture.removalService().moveToTrash(libraryID: referenced.libraryID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        let registry = await fixture.registry.snapshot()
        XCTAssertNil(registry.library(id: referenced.libraryID))
    }

    func testInspectAndExistingCreationDoNotMutateRegistry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("parent")
        let root = parent.appendingPathComponent(LibraryPaths.rootDirectoryName)
        _ = try fixture.makeLibrary(at: root, mode: .managed)

        _ = try await fixture.openService.open(selectedURL: root, activate: false)
        var registry = await fixture.registry.snapshot()
        XCTAssertTrue(registry.libraries.isEmpty)
        _ = try await fixture.creationService().create(mode: .managed, parentURL: parent, displayName: "Ignored")
        registry = await fixture.registry.snapshot()
        XCTAssertTrue(registry.libraries.isEmpty)
    }

    func testNewOpenLoadFailureRestoresEmptyRegistryAndNilSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        _ = try fixture.makeLibrary(at: root, mode: .managed)
        fixture.factory.failNextLoadForNewRoot = true

        await XCTAssertThrowsErrorAsync(try await fixture.openService.open(selectedURL: root)) {
            XCTAssertEqual($0 as? LibraryOpenError, .activationFailed)
        }
        XCTAssertNil(fixture.controller.activeLibraryContext)
        let registry = await fixture.registry.snapshot()
        XCTAssertTrue(registry.libraries.isEmpty)
    }

    func testMovedExistingOpenFailureRestoresDescriptorAndPreviousSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        let manifest = try fixture.makeLibrary(at: source, mode: .managed)
        let original = try await fixture.openService.open(selectedURL: source)
        let parent = fixture.root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let moved = parent.appendingPathComponent(LibraryPaths.rootDirectoryName)
        try FileManager.default.copyItem(at: source, to: moved)
        fixture.factory.failNextLoadForNewRoot = true

        await XCTAssertThrowsErrorAsync(try await fixture.openService.open(selectedURL: moved)) {
            XCTAssertEqual($0 as? LibraryOpenError, .activationFailed)
        }
        XCTAssertEqual(fixture.controller.activeLibraryContext, original.context)
        let registry = await fixture.registry.snapshot()
        XCTAssertEqual(registry.library(id: manifest.libraryID)?.lastKnownPath, source.path)
    }

    func testActivePointerCommitFailureRollsBackRegistryAndSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        _ = try fixture.makeLibrary(at: root, mode: .managed)
        fixture.factory.sabotageRegistryOnNextLoad = await fixture.registry.fileURL

        await XCTAssertThrowsErrorAsync(try await fixture.openService.open(selectedURL: root)) {
            XCTAssertEqual($0 as? LibraryOpenError, .activationFailed)
        }
        XCTAssertNil(fixture.controller.activeLibraryContext)
        let registry = await fixture.registry.snapshot()
        XCTAssertTrue(registry.libraries.isEmpty)
    }

    func testCreationActivationFailureDeletesDestinationAndRestoresRegistry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("parent")
        fixture.factory.failNextLoadForNewRoot = true

        await XCTAssertThrowsErrorAsync(
            try await fixture.creationService().create(mode: .managed, parentURL: parent, displayName: "New")
        ) { XCTAssertEqual($0 as? LibraryCreationError, .sessionActivationFailed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(LibraryPaths.rootDirectoryName).path))
        let registry = await fixture.registry.snapshot()
        XCTAssertTrue(registry.libraries.isEmpty)
        XCTAssertNil(fixture.controller.activeLibraryContext)
    }

    func testNonactiveRelocationRegistryFailureRestoresSourceRegistryAndNilSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        let manifest = try fixture.makeLibrary(at: source, mode: .managed)
        try await fixture.registerWithoutActivation(root: source, manifest: manifest)
        let parent = fixture.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        fixture.registryFailure.arm()

        await XCTAssertThrowsErrorAsync(
            try await fixture.relocationService().relocate(libraryID: manifest.libraryID, toParent: parent)
        ) { XCTAssertEqual($0 as? LibraryRelocationError, .registryCommitFailed) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(LibraryPaths.rootDirectoryName).path))
        XCTAssertNil(fixture.controller.activeLibraryContext)
        let registry = await fixture.registry.snapshot()
        XCTAssertEqual(registry.library(id: manifest.libraryID)?.lastKnownPath, source.path)
    }

    func testActiveSameVolumeBookmarkFailureRenamesDestinationBackAndRestoresSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        let manifest = try fixture.makeLibrary(at: source, mode: .managed)
        let opened = try await fixture.openService.open(selectedURL: source)
        let parent = fixture.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        fixture.bookmarks.failNextRefresh = true

        await XCTAssertThrowsErrorAsync(
            try await fixture.relocationService().relocate(libraryID: manifest.libraryID, toParent: parent)
        ) { XCTAssertEqual($0 as? LibraryRelocationError, .newSessionFailed) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(LibraryPaths.rootDirectoryName).path))
        XCTAssertEqual(fixture.controller.activeLibraryContext, opened.context)
        let registry = await fixture.registry.snapshot()
        XCTAssertEqual(registry.library(id: manifest.libraryID)?.lastKnownPath, source.path)
    }

    func testRelocationSecurityScopeLeasePairsOnFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        let manifest = try fixture.makeLibrary(at: source, mode: .managed)
        try await fixture.registerWithoutActivation(root: source, manifest: manifest)
        let parent = fixture.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        fixture.bookmarks.failNextRefresh = true
        let beforeStart = fixture.bookmarks.startCount
        let beforeStop = fixture.bookmarks.stopCount
        let service = LibraryRelocationService(
            registryStore: fixture.registry,
            sessionController: fixture.controller,
            sessionValidator: LibrarySessionFactoryValidator(factory: fixture.factory),
            bookmarkResolver: fixture.bookmarks,
            recycler: fixture.recycler,
            gate: fixture.gate,
            requiresSecurityScope: true
        )

        await XCTAssertThrowsErrorAsync(try await service.relocate(libraryID: manifest.libraryID, toParent: parent))
        XCTAssertEqual(fixture.bookmarks.startCount, beforeStart + 1)
        XCTAssertEqual(fixture.bookmarks.stopCount, beforeStop + 1)
    }

    func testProductionSameVolumeTransferMovesSourceAndRollbackRenamesItBack() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        let manifest = try fixture.makeLibrary(at: source, mode: .managed)
        let staging = fixture.root.appendingPathComponent("staging")
        let fileOperator = ProductionLibraryLifecycleFileOperator()

        let authority = try await fileOperator.captureRelocationAuthority(at: source)
        let transfer = try await fileOperator.relocate(from: source, toStaging: staging)
        XCTAssertEqual(transfer, .sameVolume)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        try await fileOperator.validateRelocation(at: staging, expectedAuthority: authority, expectedID: manifest.libraryID, expectedMode: .managed)
        try await fileOperator.rollbackRelocation(from: staging, to: source, transfer: transfer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testOpenRepairsMissingScaffoldingFromInPlaceMigration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed)
        // Simulate a library migrated in place from the pre-manifest layout:
        // the scoped settings file and some cache directories never existed.
        let paths = LibraryPaths(rootURL: root)
        try FileManager.default.removeItem(at: paths.librarySettingsURL)
        try FileManager.default.removeItem(at: paths.lyricsCacheRootURL)

        let opened = try await fixture.openService.open(selectedURL: root)

        XCTAssertEqual(opened.context.id, manifest.libraryID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.librarySettingsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.lyricsCacheRootURL.path))
    }

    func testRemovalIntentWriteFailureOccursBeforeRecycle() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: root)
        let blockedIntent = fixture.root.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blockedIntent, withIntermediateDirectories: false)
        let service = fixture.removalService(intentURL: blockedIntent)

        await XCTAssertThrowsErrorAsync(try await service.moveToTrash(libraryID: manifest.libraryID)) {
            XCTAssertEqual($0 as? LibraryRemovalError, .intentWriteFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        let registry = await fixture.registry.snapshot()
        XCTAssertNotNil(registry.library(id: manifest.libraryID))
        XCTAssertEqual(fixture.controller.activeLibraryContext?.id, manifest.libraryID)
    }

    func testPreparedRemovalIntentReplayKeepsRegistryWhenRootStillExists() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed)
        try await fixture.registerWithoutActivation(root: root, manifest: manifest)
        let before = await fixture.registry.snapshot()
        let intentURL = fixture.root.appendingPathComponent("repair.json")
        try LibraryRemovalRepairIntentFile.save(
            .init(libraryID: manifest.libraryID, mode: manifest.mode, rootPathBeforeRecycle: root.path, registryBefore: before),
            to: intentURL
        )
        let service = fixture.removalService(intentURL: intentURL)

        let replay = try await service.replayPendingRepair()
        XCTAssertEqual(replay, .cancelled)
        let after = await fixture.registry.snapshot()
        XCTAssertEqual(after, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: intentURL.path))
    }

    func testRemovalRegistryFailureLeavesDurableIntentAndReplayRepairsRegistry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        let manifest = try fixture.makeLibrary(at: root, mode: .referenced)
        try await fixture.registerWithoutActivation(root: root, manifest: manifest)
        let registryURL = await fixture.registry.fileURL
        let recycler = RegistrySabotagingRecycler(registryURL: registryURL)
        let intentURL = fixture.root.appendingPathComponent("repair.json")
        let service = LibraryRemovalService(
            registryStore: fixture.registry,
            sessionController: fixture.controller,
            bookmarkResolver: fixture.bookmarks,
            recycler: recycler,
            gate: fixture.gate,
            intentURL: intentURL
        )

        await XCTAssertThrowsErrorAsync(try await service.moveToTrash(libraryID: manifest.libraryID)) {
            XCTAssertEqual($0 as? LibraryRemovalError, .pendingRepair)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: intentURL.path))
        try FileManager.default.removeItem(at: registryURL)
        let replay = try await service.replayPendingRepair()
        XCTAssertEqual(replay, .removed(mode: manifest.mode, didRemoveActive: false))
        let registry = await fixture.registry.snapshot()
        XCTAssertNil(registry.library(id: manifest.libraryID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: intentURL.path))
    }

    func testRemovalSecurityScopeLeasePairsOnSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed)
        try await fixture.registerWithoutActivation(root: root, manifest: manifest)
        let beforeStart = fixture.bookmarks.startCount
        let beforeStop = fixture.bookmarks.stopCount

        _ = try await fixture.removalService(requiresSecurityScope: true).moveToTrash(libraryID: manifest.libraryID)
        XCTAssertEqual(fixture.bookmarks.startCount, beforeStart + 1)
        XCTAssertEqual(fixture.bookmarks.stopCount, beforeStop + 1)
    }

    func testSecurityScopeLeasePairsStartAndStopForRename() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed)
        try await fixture.registerWithoutActivation(root: root, manifest: manifest)
        let service = fixture.removalService(requiresSecurityScope: true)
        let beforeStart = fixture.bookmarks.startCount
        let beforeStop = fixture.bookmarks.stopCount

        try await service.updateDisplayName(libraryID: manifest.libraryID, displayName: "Renamed")
        XCTAssertEqual(fixture.bookmarks.startCount, beforeStart + 1)
        XCTAssertEqual(fixture.bookmarks.stopCount, beforeStop + 1)
    }

    func testSharedGateRejectsCrossServiceTransaction() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        _ = try fixture.makeLibrary(at: root, mode: .managed)
        try fixture.gate.acquire()
        defer { fixture.gate.release() }

        await XCTAssertThrowsErrorAsync(try await fixture.openService.open(selectedURL: root)) {
            XCTAssertEqual($0 as? LibraryOpenError, .transactionInProgress)
        }
        await XCTAssertThrowsErrorAsync(
            try await fixture.creationService().create(mode: .managed, parentURL: fixture.root, displayName: "Busy")
        ) { XCTAssertEqual($0 as? LibraryCreationError, .stagingFailed) }
    }

    func testRenameRegistryFailureRollsManifestBack() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed, displayName: "Before")
        try await fixture.registerWithoutActivation(root: root, manifest: manifest)
        let registryURL = await fixture.registry.fileURL
        try FileManager.default.removeItem(at: registryURL)
        try FileManager.default.createDirectory(at: registryURL, withIntermediateDirectories: false)

        await XCTAssertThrowsErrorAsync(
            try await fixture.removalService().updateDisplayName(libraryID: manifest.libraryID, displayName: "After")
        ) { XCTAssertEqual($0 as? LibraryDisplayNameUpdateError, .registryWriteFailedRolledBack) }
        XCTAssertEqual(try MusicLibraryManifest.read(from: LibraryPaths(rootURL: root).manifestURL).displayName, "Before")
    }

    func testRelocationReplayRestoresSourceMovedStagingAfterRelaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        let manifest = try fixture.makeLibrary(at: source, mode: .managed)
        try await fixture.registerWithoutActivation(root: source, manifest: manifest)
        let parent = fixture.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".relocation-staging")
        let destination = parent.appendingPathComponent(LibraryPaths.rootDirectoryName)
        let journal = fixture.root.appendingPathComponent("Relocation.json")
        let fileOperator = ProductionLibraryLifecycleFileOperator()
        let authority = try await fileOperator.captureRelocationAuthority(at: source)
        let intent = LibraryRelocationRepairIntent(
            libraryID: manifest.libraryID,
            mode: manifest.mode,
            source: source,
            staging: staging,
            destination: destination,
            authority: authority,
            registryBefore: await fixture.registry.snapshot()
        )
        try LibraryRelocationRepairIntentFile.save(intent, to: journal)
        _ = try await fileOperator.relocate(from: source, toStaging: staging)
        // Simulate termination before sourceMoved can be persisted.

        let relaunched = LibraryRelocationService(
            registryStore: fixture.registry,
            sessionController: fixture.controller,
            sessionValidator: LibrarySessionFactoryValidator(factory: fixture.factory),
            bookmarkResolver: fixture.bookmarks,
            recycler: fixture.recycler,
            intentURL: journal
        )
        let didReplay = try await relaunched.replayPendingRepair()
        XCTAssertTrue(didReplay)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testRelocationReplayRollsPublishedDestinationBackAfterRelaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        let manifest = try fixture.makeLibrary(at: source, mode: .referenced)
        try await fixture.registerWithoutActivation(root: source, manifest: manifest)
        let parent = fixture.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".relocation-staging")
        let destination = parent.appendingPathComponent(LibraryPaths.rootDirectoryName)
        let journal = fixture.root.appendingPathComponent("Relocation.json")
        let fileOperator = ProductionLibraryLifecycleFileOperator()
        let authority = try await fileOperator.captureRelocationAuthority(at: source)
        var intent = LibraryRelocationRepairIntent(
            libraryID: manifest.libraryID,
            mode: manifest.mode,
            source: source,
            staging: staging,
            destination: destination,
            authority: authority,
            registryBefore: await fixture.registry.snapshot()
        )
        try LibraryRelocationRepairIntentFile.save(intent, to: journal)
        intent.transfer = try await fileOperator.relocate(from: source, toStaging: staging)
        try await fileOperator.publishStaging(at: staging, to: destination)
        intent.phase = .published
        try LibraryRelocationRepairIntentFile.save(intent, to: journal)

        let relaunched = LibraryRelocationService(
            registryStore: fixture.registry,
            sessionController: fixture.controller,
            sessionValidator: LibrarySessionFactoryValidator(factory: fixture.factory),
            bookmarkResolver: fixture.bookmarks,
            recycler: fixture.recycler,
            intentURL: journal
        )
        let didReplay = try await relaunched.replayPendingRepair()
        XCTAssertTrue(didReplay)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCrossVolumePreparedReplayRemovesOnlyMatchingOrphan() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        let manifest = try fixture.makeLibrary(at: source, mode: .managed)
        try await fixture.registerWithoutActivation(root: source, manifest: manifest)
        let staging = fixture.root.appendingPathComponent("orphan")
        try FileManager.default.copyItem(at: source, to: staging)
        let destination = fixture.root.appendingPathComponent("unused")
        let journal = fixture.root.appendingPathComponent("Relocation.json")
        let fileOperator = ProductionLibraryLifecycleFileOperator()
        let authority = try await fileOperator.captureRelocationAuthority(at: source)
        var intent = LibraryRelocationRepairIntent(
            libraryID: manifest.libraryID,
            mode: manifest.mode,
            source: source,
            staging: staging,
            destination: destination,
            authority: authority,
            registryBefore: await fixture.registry.snapshot()
        )
        intent.transfer = .copiedAcrossVolumes
        intent.phase = .sourceMoved
        try LibraryRelocationRepairIntentFile.save(intent, to: journal)
        let service = LibraryRelocationService(
            registryStore: fixture.registry,
            sessionController: fixture.controller,
            sessionValidator: LibrarySessionFactoryValidator(factory: fixture.factory),
            bookmarkResolver: fixture.bookmarks,
            recycler: fixture.recycler,
            intentURL: journal
        )

        let didReplay = try await service.replayPendingRepair()
        XCTAssertTrue(didReplay)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testRelocationReplayFinishesRegistryCommittedPhaseAfterRelaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        let manifest = try fixture.makeLibrary(at: source, mode: .managed)
        try await fixture.registerWithoutActivation(root: source, manifest: manifest)
        let before = await fixture.registry.snapshot()
        let parent = fixture.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".relocation-staging")
        let destination = parent.appendingPathComponent(LibraryPaths.rootDirectoryName)
        let journal = fixture.root.appendingPathComponent("Relocation.json")
        let fileOperator = ProductionLibraryLifecycleFileOperator()
        let authority = try await fileOperator.captureRelocationAuthority(at: source)
        var intent = LibraryRelocationRepairIntent(
            libraryID: manifest.libraryID,
            mode: manifest.mode,
            source: source,
            staging: staging,
            destination: destination,
            authority: authority,
            registryBefore: before
        )
        intent.transfer = try await fileOperator.relocate(from: source, toStaging: staging)
        try await fileOperator.publishStaging(at: staging, to: destination)
        let bookmark = try fixture.bookmarks.refreshBookmark(for: destination)
        intent.destinationBookmark = bookmark
        intent.phase = .registryCommitted
        try LibraryRelocationRepairIntentFile.save(intent, to: journal)
        var committed = before
        let index = try XCTUnwrap(committed.libraries.firstIndex(where: { $0.id == manifest.libraryID }))
        committed.libraries[index].rootBookmarkData = bookmark
        committed.libraries[index].lastKnownPath = destination.path
        try await fixture.registry.replaceSnapshot(committed)

        let service = LibraryRelocationService(
            registryStore: fixture.registry,
            sessionController: fixture.controller,
            sessionValidator: LibrarySessionFactoryValidator(factory: fixture.factory),
            bookmarkResolver: fixture.bookmarks,
            recycler: fixture.recycler,
            intentURL: journal
        )
        let didReplay = try await service.replayPendingRepair()
        XCTAssertTrue(didReplay)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        let registryAfter = await fixture.registry.snapshot()
        XCTAssertEqual(registryAfter.library(id: manifest.libraryID)?.lastKnownPath, destination.path)
    }

    func testRelocationReplayStopsOnForeignStagingIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        let manifest = try fixture.makeLibrary(at: source, mode: .managed)
        try await fixture.registerWithoutActivation(root: source, manifest: manifest)
        let fileOperator = ProductionLibraryLifecycleFileOperator()
        let authority = try await fileOperator.captureRelocationAuthority(at: source)
        let staging = fixture.root.appendingPathComponent("staging")
        try FileManager.default.removeItem(at: source)
        _ = try fixture.makeLibrary(at: staging, mode: .referenced)
        let journal = fixture.root.appendingPathComponent("Relocation.json")
        var intent = LibraryRelocationRepairIntent(
            libraryID: manifest.libraryID,
            mode: manifest.mode,
            source: source,
            staging: staging,
            destination: fixture.root.appendingPathComponent("destination"),
            authority: authority,
            registryBefore: await fixture.registry.snapshot()
        )
        intent.transfer = .sameVolume
        intent.phase = .sourceMoved
        try LibraryRelocationRepairIntentFile.save(intent, to: journal)
        let service = LibraryRelocationService(
            registryStore: fixture.registry,
            sessionController: fixture.controller,
            sessionValidator: LibrarySessionFactoryValidator(factory: fixture.factory),
            bookmarkResolver: fixture.bookmarks,
            recycler: fixture.recycler,
            intentURL: journal
        )

        await XCTAssertThrowsErrorAsync(try await service.replayPendingRepair()) {
            XCTAssertEqual($0 as? LibraryRelocationError, .recoveryConflict)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }

    func testRemovalReplayRepairsRegistryWhenPathReusedByDifferentLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("reused")
        let old = try fixture.makeLibrary(at: root, mode: .managed)
        try await fixture.registerWithoutActivation(root: root, manifest: old)
        let before = await fixture.registry.snapshot()
        let journal = fixture.root.appendingPathComponent("Removal.json")
        try FileManager.default.removeItem(at: root)
        let replacement = try fixture.makeLibrary(at: root, mode: .referenced)
        try LibraryRemovalRepairIntentFile.save(
            .init(libraryID: old.libraryID, mode: old.mode, rootPathBeforeRecycle: root.path, registryBefore: before),
            to: journal
        )

        let replay = try await fixture.removalService(intentURL: journal).replayPendingRepair()
        let registryAfter = await fixture.registry.snapshot()
        XCTAssertEqual(replay, .removed(mode: old.mode, didRemoveActive: false))
        XCTAssertNil(registryAfter.library(id: old.libraryID))
        XCTAssertEqual(try MusicLibraryManifest.read(from: LibraryPaths(rootURL: root).manifestURL).libraryID, replacement.libraryID)
    }

    func testRemovalReplayRepairsRegistryWhenPathReusedByInvalidDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("reused")
        let old = try fixture.makeLibrary(at: root, mode: .managed)
        try await fixture.registerWithoutActivation(root: root, manifest: old)
        let before = await fixture.registry.snapshot()
        let journal = fixture.root.appendingPathComponent("Removal.json")
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: root.appendingPathComponent("keep"))
        try LibraryRemovalRepairIntentFile.save(
            .init(libraryID: old.libraryID, mode: old.mode, rootPathBeforeRecycle: root.path, registryBefore: before),
            to: journal
        )

        let replay = try await fixture.removalService(intentURL: journal).replayPendingRepair()
        let registryAfter = await fixture.registry.snapshot()
        XCTAssertEqual(replay, .removed(mode: old.mode, didRemoveActive: false))
        XCTAssertNil(registryAfter.library(id: old.libraryID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep").path))
    }

    func testStartupResolverNeverReturnsRemovedInitialLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let oldRoot = fixture.root.appendingPathComponent("old")
        let old = try fixture.makeLibrary(at: oldRoot, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: oldRoot)
        let fallbackRoot = fixture.root.appendingPathComponent("fallback")
        let fallback = try fixture.makeLibrary(at: fallbackRoot, mode: .managed)
        try await fixture.registerWithoutActivation(root: fallbackRoot, manifest: fallback)
        try FileManager.default.removeItem(at: oldRoot)
        try await fixture.registry.remove(libraryID: old.libraryID)

        let resolution = await LibraryStartupContextResolver(
            registryStore: fixture.registry,
            bookmarkResolver: fixture.bookmarks
        ).resolve(allowSuccessorAfterRemoval: .managed)
        guard case .context(let context) = resolution else { return XCTFail("Expected successor") }
        XCTAssertEqual(context.id, fallback.libraryID)
        XCTAssertNotEqual(context.id, old.libraryID)
    }

    func testStartupActiveBookmarkFailureDoesNotFallbackToHealthyLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let activeRoot = fixture.root.appendingPathComponent("active")
        let active = try fixture.makeLibrary(at: activeRoot, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: activeRoot)
        let healthyRoot = fixture.root.appendingPathComponent("healthy")
        let healthy = try fixture.makeLibrary(at: healthyRoot, mode: .managed)
        try await fixture.registerWithoutActivation(root: healthyRoot, manifest: healthy)
        var registry = await fixture.registry.snapshot()
        let index = try XCTUnwrap(registry.libraries.firstIndex(where: { $0.id == active.libraryID }))
        registry.libraries[index].rootBookmarkData = Data([0xFF])
        try await fixture.registry.replaceSnapshot(registry)
        let startsBefore = fixture.bookmarks.startCount

        let resolution = await LibraryStartupContextResolver(
            registryStore: fixture.registry,
            bookmarkResolver: fixture.bookmarks
        ).resolve()
        XCTAssertEqual(resolution, .unavailable)
        XCTAssertEqual(fixture.bookmarks.startCount, startsBefore)
    }

    func testStartupActiveManifestMismatchDoesNotFallbackToHealthyLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let activeRoot = fixture.root.appendingPathComponent("active")
        _ = try fixture.makeLibrary(at: activeRoot, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: activeRoot)
        let healthyRoot = fixture.root.appendingPathComponent("healthy")
        let healthy = try fixture.makeLibrary(at: healthyRoot, mode: .managed)
        try await fixture.registerWithoutActivation(root: healthyRoot, manifest: healthy)
        let mismatched = MusicLibraryManifest(displayName: "Different", mode: .managed)
        try mismatched.write(to: LibraryPaths(rootURL: activeRoot).manifestURL)
        let startsBefore = fixture.bookmarks.startCount

        let resolution = await LibraryStartupContextResolver(
            registryStore: fixture.registry,
            bookmarkResolver: fixture.bookmarks
        ).resolve()
        XCTAssertEqual(resolution, .unavailable)
        XCTAssertEqual(fixture.bookmarks.startCount, startsBefore + 1)
    }

    func testStartupWithNilActiveDoesNotAutomaticallyOpenRecentLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("recent")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: root)
        var registry = await fixture.registry.snapshot()
        XCTAssertEqual(registry.recentManagedLibraryID, manifest.libraryID)
        registry.activeLibraryID = nil
        try await fixture.registry.replaceSnapshot(registry)
        let startsBefore = fixture.bookmarks.startCount

        let resolution = await LibraryStartupContextResolver(
            registryStore: fixture.registry,
            bookmarkResolver: fixture.bookmarks
        ).resolve()
        XCTAssertEqual(resolution, .noActive)
        XCTAssertEqual(fixture.bookmarks.startCount, startsBefore)
    }

    func testStartupRemovalRepairMaySelectSuccessorOnlyAfterRemovingActive() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let removedRoot = fixture.root.appendingPathComponent("removed")
        let removed = try fixture.makeLibrary(at: removedRoot, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: removedRoot)
        let successorRoot = fixture.root.appendingPathComponent("successor")
        let successor = try fixture.makeLibrary(at: successorRoot, mode: .managed)
        try await fixture.registerWithoutActivation(root: successorRoot, manifest: successor)
        let before = await fixture.registry.snapshot()
        let journal = fixture.root.appendingPathComponent("Removal.json")
        try LibraryRemovalRepairIntentFile.save(
            .init(
                libraryID: removed.libraryID,
                mode: removed.mode,
                rootPathBeforeRecycle: removedRoot.path,
                registryBefore: before
            ),
            to: journal
        )
        try FileManager.default.removeItem(at: removedRoot)

        let replay = try await fixture.removalService(intentURL: journal).replayPendingRepair()
        XCTAssertEqual(replay, .removed(mode: .managed, didRemoveActive: true))
        let resolution = await LibraryStartupContextResolver(
            registryStore: fixture.registry,
            bookmarkResolver: fixture.bookmarks
        ).resolve(allowSuccessorAfterRemoval: .managed)
        guard case .context(let context) = resolution else { return XCTFail("Expected successor") }
        XCTAssertEqual(context.id, successor.libraryID)
    }

    func testRenameRefreshesStaleBookmarkAndPairsScope() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed)
        try await fixture.registerWithoutActivation(root: root, manifest: manifest)
        fixture.bookmarks.isStale = true
        let refreshBefore = fixture.bookmarks.refreshCount
        let startBefore = fixture.bookmarks.startCount
        let stopBefore = fixture.bookmarks.stopCount

        try await fixture.removalService(requiresSecurityScope: true)
            .updateDisplayName(libraryID: manifest.libraryID, displayName: "Renamed")
        XCTAssertEqual(fixture.bookmarks.refreshCount, refreshBefore + 1)
        XCTAssertEqual(fixture.bookmarks.startCount, startBefore + 1)
        XCTAssertEqual(fixture.bookmarks.stopCount, stopBefore + 1)
    }

    func testNonactiveRelocationValidationNeverPublishesActiveSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let activeRoot = fixture.root.appendingPathComponent("active")
        _ = try fixture.makeLibrary(at: activeRoot, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: activeRoot)
        let source = fixture.root.appendingPathComponent("nonactive")
        let moved = try fixture.makeLibrary(at: source, mode: .referenced)
        try await fixture.registerWithoutActivation(root: source, manifest: moved)
        var activations: [UUID] = []
        fixture.controller.didActivateSession = { session in activations.append(session.context.id) }
        let parent = fixture.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        _ = try await fixture.relocationService().relocate(libraryID: moved.libraryID, toParent: parent)
        XCTAssertTrue(activations.isEmpty)
        XCTAssertNotEqual(fixture.controller.activeLibraryContext?.id, moved.libraryID)
    }
}

private final class LifecycleTestBookmarkResolver: kmgccc_player.BookmarkResolving, @unchecked Sendable {
    private let lock = NSLock()
    var isStale = false
    var allowsAccess = true
    var failNextRefresh = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var refreshCount = 0
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        guard let path = String(data: data, encoding: .utf8) else { throw TestError.expected }
        return (URL(fileURLWithPath: path, isDirectory: true), isStale)
    }
    func refreshBookmark(for url: URL) throws -> Data {
        refreshCount += 1
        if failNextRefresh { failNextRefresh = false; throw TestError.expected }
        return Data(url.standardizedFileURL.path.utf8)
    }
    func startAccessing(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        startCount += 1
        return allowsAccess
    }
    func stopAccessing(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        stopCount += 1
    }
}

@MainActor
private final class LifecycleTestSessionFactory: kmgccc_player.LibrarySessionBuilding {
    var failNextLoadForNewRoot = false
    var sabotageRegistryOnNextLoad: URL?
    private var lastLoadedRoot: URL?

    func makeSession(for context: kmgccc_player.LibraryContext) async throws -> any kmgccc_player.LibrarySessionLifecycle {
        let shouldFail = failNextLoadForNewRoot && context.rootURL != lastLoadedRoot
        if shouldFail { failNextLoadForNewRoot = false }
        let sabotageURL = sabotageRegistryOnNextLoad
        sabotageRegistryOnNextLoad = nil
        return LifecycleTestSession(
            context: context,
            failLoad: shouldFail,
            didLoad: { [weak self] root in
                self?.lastLoadedRoot = root
                guard let sabotageURL else { return }
                try? FileManager.default.removeItem(at: sabotageURL)
                try? FileManager.default.createDirectory(at: sabotageURL, withIntermediateDirectories: false)
            },
            didClose: {
                guard let sabotageURL else { return }
                try? FileManager.default.removeItem(at: sabotageURL)
            }
        )
    }
}

@MainActor
private final class LifecycleTestSession: kmgccc_player.LibrarySessionLifecycle {
    let context: kmgccc_player.LibraryContext
    let failLoad: Bool
    let didLoad: (URL) -> Void
    let didClose: () -> Void
    init(
        context: kmgccc_player.LibraryContext,
        failLoad: Bool,
        didLoad: @escaping (URL) -> Void,
        didClose: @escaping () -> Void = {}
    ) {
        self.context = context
        self.failLoad = failLoad
        self.didLoad = didLoad
        self.didClose = didClose
    }
    func load() async throws { if failLoad { throw TestError.expected }; didLoad(context.rootURL) }
    func flush() async throws {}
    func quiesce() async {}
    func close() async { didClose() }
}

private actor LifecycleTestRecycler: kmgccc_player.LibraryRecycling {
    let shouldFail: Bool
    init(shouldFail: Bool) { self.shouldFail = shouldFail }
    func recycle(_ url: URL) async throws {
        if shouldFail { throw TestError.expected }
        try FileManager.default.removeItem(at: url)
    }
}

private final class RegistryCommitFailureInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 0
    func arm() { lock.lock(); remaining = 1; lock.unlock() }
    func callAsFunction() throws {
        lock.lock(); defer { lock.unlock() }
        guard remaining > 0 else { return }
        remaining -= 1
        throw TestError.expected
    }
}

private actor RegistrySabotagingRecycler: kmgccc_player.LibraryRecycling {
    let registryURL: URL
    init(registryURL: URL) { self.registryURL = registryURL }
    func recycle(_ url: URL) async throws {
        try FileManager.default.removeItem(at: url)
        try FileManager.default.removeItem(at: registryURL)
        try FileManager.default.createDirectory(at: registryURL, withIntermediateDirectories: false)
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let registry: kmgccc_player.MusicLibraryRegistryStore
    let registryFailure: RegistryCommitFailureInjector
    let bookmarks = LifecycleTestBookmarkResolver()
    let factory = LifecycleTestSessionFactory()
    let controller: kmgccc_player.LibrarySessionController
    let gate = LibraryLifecycleTransactionGate()
    let openService: LibraryOpenService
    let recycler: LifecycleTestRecycler

    init(recyclerFails: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registryFailure = RegistryCommitFailureInjector()
        self.registryFailure = registryFailure
        registry = try kmgccc_player.MusicLibraryRegistryStore(
            fileURL: root.appendingPathComponent("Registry.json"),
            beforeCommit: { try registryFailure() }
        )
        controller = kmgccc_player.LibrarySessionController(factory: factory)
        recycler = LifecycleTestRecycler(shouldFail: recyclerFails)
        openService = LibraryOpenService(
            registryStore: registry,
            sessionController: controller,
            bookmarkResolver: bookmarks,
            gate: gate
        )
    }

    func creationService() -> LibraryCreationService {
        LibraryCreationService(
            registryStore: registry,
            openService: openService,
            bookmarkResolver: bookmarks,
            gate: gate
        )
    }

    func relocationService() -> LibraryRelocationService {
        LibraryRelocationService(
            registryStore: registry,
            sessionController: controller,
            sessionValidator: LibrarySessionFactoryValidator(factory: factory),
            bookmarkResolver: bookmarks,
            recycler: recycler,
            gate: gate
        )
    }

    func removalService(
        requiresSecurityScope: Bool = false,
        intentURL: URL? = nil
    ) -> LibraryRemovalService {
        LibraryRemovalService(
            registryStore: registry,
            sessionController: controller,
            bookmarkResolver: bookmarks,
            recycler: recycler,
            gate: gate,
            requiresSecurityScope: requiresSecurityScope,
            intentURL: intentURL
        )
    }

    func registerWithoutActivation(root: URL, manifest: kmgccc_player.MusicLibraryManifest) async throws {
        let bookmark = try bookmarks.refreshBookmark(for: root)
        try await registry.register(try kmgccc_player.MusicLibraryBookmark.make(
            manifest: manifest,
            rootURL: root,
            bookmarkData: bookmark
        ))
    }

    func makeLibrary(
        at url: URL,
        mode: kmgccc_player.MusicLibraryMode,
        displayName: String = "Library"
    ) throws -> kmgccc_player.MusicLibraryManifest {
        let manifest = kmgccc_player.MusicLibraryManifest(displayName: displayName, mode: mode)
        let paths = LibraryPaths(rootURL: url)
        try paths.createRequiredDirectories()
        try manifest.write(to: paths.manifestURL)
        try Data("{}".utf8).write(to: paths.librarySettingsURL)
        return manifest
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private enum TestError: Error { case expected }

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error")
    } catch {
        errorHandler(error)
    }
}
