import XCTest
import Darwin
@testable import kmgccc_player

@MainActor
final class LibraryLifecycleTransactionTests: XCTestCase {
    func testCreationBuildsNamedRootAndActivatesProductionTransaction() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = fixture.creationService()

        let result = try await service.create(
            mode: .managed,
            parentURL: fixture.root.appendingPathComponent("parent"),
            displayName: "Music"
        )
        guard case .created(let context, _) = result else { return XCTFail("Expected creation") }
        XCTAssertEqual(context.rootURL.lastPathComponent, "kmgccc_player Library - Music")
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.paths.librarySettingsURL.path))
        XCTAssertEqual(fixture.controller.activeLibraryContext?.id, context.id)
        let registry = await fixture.registry.snapshot()
        XCTAssertEqual(registry.activeLibraryID, context.id)
    }

    func testCreationRejectsNonemptyInvalidDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("parent")
        let destination = parent.appendingPathComponent("kmgccc_player Library - Music")
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
            displayName: "Reference"
        )
        guard case .existingLibraryModeMismatch(let opened, let requested) = result else { return XCTFail() }
        XCTAssertEqual(opened.id, original.id)
        XCTAssertEqual(requested, .managed)
        XCTAssertEqual(try MusicLibraryManifest.read(from: opened.paths.manifestURL).displayName, "Reference")
    }

    func testCreationSelectingExistingRootDoesNotNestAnotherLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("parent")
        let existing = try await fixture.creationService().create(
            mode: .referenced,
            parentURL: parent,
            displayName: "Reference"
        )
        guard case let .created(original, _) = existing else { return XCTFail("Expected creation") }

        let selectedRoot = original.rootURL
        let result = try await fixture.creationService().create(
            mode: .referenced,
            parentURL: selectedRoot,
            displayName: "Should Not Nest"
        )
        guard case let .existingLibrary(opened) = result else {
            return XCTFail("Selecting the existing root should open it")
        }
        XCTAssertEqual(opened.id, original.id)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: selectedRoot.appendingPathComponent("kmgccc_player Library - Should Not Nest").path
            )
        )
        XCTAssertEqual(
            try MusicLibraryManifest.read(from: original.paths.manifestURL).displayName,
            "Reference"
        )
    }

    func testCreationInLegacyDefaultParentKeepsExistingLibraryUnchanged() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("Music")
        let legacyRoot = parent.appendingPathComponent(LibraryPaths.rootDirectoryName)
        let legacy = try fixture.makeLibrary(at: legacyRoot, mode: .referenced, displayName: "旧资料库")
        let legacyPaths = LibraryPaths(rootURL: legacyRoot)
        let manifestBefore = try Data(contentsOf: legacyPaths.manifestURL)
        let settingsBefore = try Data(contentsOf: legacyPaths.librarySettingsURL)
        _ = try await fixture.openService.open(selectedURL: parent)

        var createdIDs: [UUID] = []
        for (name, mode) in [("古典", MusicLibraryMode.managed), ("爵士", .referenced)] {
            let result = try await fixture.creationService().create(
                mode: mode,
                parentURL: parent,
                displayName: name,
                allowAlternateDestinationWhenOccupied: true
            )
            guard case .created(let context, _) = result else { return XCTFail("Expected a new sibling") }
            XCTAssertEqual(context.rootURL.lastPathComponent, "kmgccc_player Library - \(name)")
            XCTAssertEqual(context.rootURL.deletingLastPathComponent().path, parent.standardizedFileURL.path)
            createdIDs.append(context.id)
        }

        XCTAssertEqual(Set(createdIDs).count, 2)
        XCTAssertFalse(createdIDs.contains(legacy.libraryID))
        XCTAssertEqual(try Data(contentsOf: legacyPaths.manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: legacyPaths.librarySettingsURL), settingsBefore)
        let reopened = try await fixture.openService.open(selectedURL: parent)
        XCTAssertEqual(reopened.context.id, legacy.libraryID)
        XCTAssertEqual(reopened.context.rootURL.path, legacyRoot.standardizedFileURL.path)
        let registry = await fixture.registry.snapshot()
        XCTAssertEqual(registry.libraries.count, 3)
    }

    func testFirstRunCreationCanReuseDefaultParentAndNameInEitherMode() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("Music")
        let service = fixture.creationService()
        let defaultResult = try await service.create(
            mode: .referenced,
            parentURL: parent,
            displayName: "音乐资料库",
            allowAlternateDestinationWhenOccupied: true
        )
        guard case .created(let original, _) = defaultResult else { return XCTFail() }
        let manifestBefore = try Data(contentsOf: original.paths.manifestURL)
        let settingsBefore = try Data(contentsOf: original.paths.librarySettingsURL)

        for (index, mode) in [MusicLibraryMode.managed, .referenced].enumerated() {
            let result = try await service.create(
                mode: mode,
                parentURL: parent,
                displayName: "音乐资料库",
                allowAlternateDestinationWhenOccupied: true
            )
            guard case .created(let context, _) = result else { return XCTFail("Expected a numbered sibling") }
            XCTAssertEqual(context.rootURL.lastPathComponent, "kmgccc_player Library - 音乐资料库 \(index + 2)")
            XCTAssertNotEqual(context.id, original.id)
            XCTAssertEqual(context.mode, mode)
            XCTAssertEqual(fixture.controller.activeLibraryContext?.id, context.id)
        }

        XCTAssertEqual(try Data(contentsOf: original.paths.manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: original.paths.librarySettingsURL), settingsBefore)
        let registry = await fixture.registry.snapshot()
        XCTAssertEqual(registry.libraries.count, 3)
    }

    func testNumberedCreationSkipsOccupiedFoldersWithoutRepairingOrRemovingThem() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("parent")
        let occupied = parent.appendingPathComponent("kmgccc_player Library - Music")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        let manifest = kmgccc_player.MusicLibraryManifest(displayName: "Existing", mode: .referenced)
        try manifest.write(to: LibraryPaths(rootURL: occupied).manifestURL)
        let manifestBefore = try Data(contentsOf: LibraryPaths(rootURL: occupied).manifestURL)
        let unknown = parent.appendingPathComponent("kmgccc_player Library - Music 2")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        let sentinel = unknown.appendingPathComponent("keep.txt")
        try Data("foreign".utf8).write(to: sentinel)

        let result = try await fixture.creationService().create(
            mode: .managed,
            parentURL: parent,
            displayName: "Music",
            allowAlternateDestinationWhenOccupied: true
        )
        guard case .created(let context, _) = result else { return XCTFail("Expected an available sibling") }
        XCTAssertEqual(context.rootURL.lastPathComponent, "kmgccc_player Library - Music 3")
        XCTAssertEqual(try Data(contentsOf: LibraryPaths(rootURL: occupied).manifestURL), manifestBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LibraryPaths(rootURL: occupied).settingsRootURL.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("foreign".utf8))
    }

    func testCreationSanitizesOnlyDirectoryNameAndKeepsFullDisplayName() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("parent")
        let displayName = "  古典/现场:精选\\收藏\n终版  "
        let result = try await fixture.creationService().create(
            mode: .managed,
            parentURL: parent,
            displayName: displayName
        )
        guard case .created(let context, _) = result else { return XCTFail() }
        XCTAssertEqual(context.rootURL.lastPathComponent, "kmgccc_player Library - 古典-现场-精选-收藏-终版")
        XCTAssertEqual(context.rootURL.deletingLastPathComponent().path, parent.standardizedFileURL.path)
        XCTAssertEqual(
            try MusicLibraryManifest.read(from: context.paths.manifestURL).displayName,
            displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let reopened = try await fixture.openService.open(selectedURL: context.rootURL)
        XCTAssertEqual(reopened.context.id, context.id)
    }

    func testCreationWithLongUnicodeNameKeepsFullNameInManifest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let displayName = String(repeating: "音乐🎵", count: 40)
        let result = try await fixture.creationService().create(
            mode: .referenced,
            parentURL: fixture.root.appendingPathComponent("parent"),
            displayName: displayName
        )
        guard case .created(let context, _) = result else { return XCTFail() }
        XCTAssertLessThan(context.rootURL.lastPathComponent.utf8.count, 240)
        XCTAssertEqual(try MusicLibraryManifest.read(from: context.paths.manifestURL).displayName, displayName)
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

    func testStartupResolverUsesReachableLibraryWhenActivePointerIsMissing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("reachable")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed)
        try await fixture.registerWithoutActivation(root: root, manifest: manifest)

        var registry = await fixture.registry.snapshot()
        registry.activeLibraryID = nil
        try await fixture.registry.replaceSnapshot(registry)

        let resolution = await LibraryStartupContextResolver(
            registryStore: fixture.registry,
            bookmarkResolver: fixture.bookmarks
        ).resolve()
        guard case .context(let context) = resolution else {
            return XCTFail("Expected the reachable registered library to be selected")
        }
        XCTAssertEqual(context.id, manifest.libraryID)
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

    func testActiveRelocationRegistryFailureClosesDestinationBeforeRollback() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        let manifest = try fixture.makeLibrary(at: source, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: source)
        let parent = fixture.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        fixture.registryFailure.arm()

        await XCTAssertThrowsErrorAsync(
            try await fixture.relocationService().relocate(libraryID: manifest.libraryID, toParent: parent)
        ) { error in
            XCTAssertEqual(error as? LibraryRelocationError, .registryCommitFailed)
        }

        XCTAssertEqual(fixture.controller.activeLibraryContext?.id, manifest.libraryID)
        XCTAssertEqual(fixture.controller.activeLibraryContext?.rootURL, source.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: parent.appendingPathComponent(LibraryPaths.rootDirectoryName).path
        ))
        let stored = await fixture.registry.snapshot()
        XCTAssertEqual(
            stored.library(id: manifest.libraryID)?.lastKnownPath,
            source.standardizedFileURL.path
        )
    }

    func testInactiveLibraryWithWriterLeaseCannotBeMovedOrRecycled() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("busy")
        let manifest = try fixture.makeLibrary(at: source, mode: .managed)
        try await fixture.registerWithoutActivation(root: source, manifest: manifest)
        let lease = try LibraryWriterLease.acquire(paths: LibraryPaths(rootURL: source))
        defer { lease.release() }
        let parent = fixture.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        await XCTAssertThrowsErrorAsync(
            try await fixture.relocationService().relocate(libraryID: manifest.libraryID, toParent: parent)
        ) { XCTAssertTrue($0 is LibraryWriterLeaseError) }
        await XCTAssertThrowsErrorAsync(
            try await fixture.removalService().moveToTrash(libraryID: manifest.libraryID)
        ) { XCTAssertTrue($0 is LibraryWriterLeaseError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(LibraryPaths.rootDirectoryName).path))
        let registry = await fixture.registry.snapshot()
        XCTAssertNotNil(registry.library(id: manifest.libraryID))
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

    func testActiveRemovalSkipsInvalidSuccessorAndActivatesNextReachableLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let activeRoot = fixture.root.appendingPathComponent("active")
        let active = try fixture.makeLibrary(at: activeRoot, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: activeRoot)

        let reachableRoot = fixture.root.appendingPathComponent("reachable")
        let reachable = try fixture.makeLibrary(at: reachableRoot, mode: .managed)
        try await fixture.registerWithoutActivation(root: reachableRoot, manifest: reachable)

        let brokenRoot = fixture.root.appendingPathComponent("broken")
        let broken = try fixture.makeLibrary(at: brokenRoot, mode: .managed)
        try await fixture.registerWithoutActivation(root: brokenRoot, manifest: broken)
        try FileManager.default.removeItem(at: LibraryPaths(rootURL: brokenRoot).manifestURL)

        let result = try await fixture.removalService().moveToTrash(libraryID: active.libraryID)
        guard case .activated(let context) = result else {
            return XCTFail("Expected the next reachable library to be activated")
        }
        XCTAssertEqual(context.id, reachable.libraryID)
        XCTAssertEqual(fixture.controller.activeLibraryContext?.id, reachable.libraryID)
        let registry = await fixture.registry.snapshot()
        XCTAssertEqual(registry.activeLibraryID, reachable.libraryID)
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
        _ = try await fixture.creationService().create(mode: .managed, parentURL: root, displayName: "Ignored")
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
            XCTAssertEqual($0 as? LibraryOpenError, .registryCommitFailed)
        }
        XCTAssertNil(fixture.controller.activeLibraryContext)
        let registry = await fixture.registry.snapshot()
        XCTAssertTrue(registry.libraries.isEmpty)
    }

    func testFailedSourceCheckAfterActivationKeepsLibraryOpen() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("referenced")
        _ = try fixture.makeLibrary(at: root, mode: .referenced)
        let opened = try await fixture.openService.open(selectedURL: root)
        let registryBefore = await fixture.registry.snapshot()
        let paths = opened.context.paths
        // A disconnected or changed source index after activation is an
        // ancillary failure, not a failed library opening.
        try FileManager.default.removeItem(at: paths.sourcesRootURL)
        try Data("unreadable source directory".utf8).write(to: paths.sourcesRootURL)

        let sourceIDs = await LibraryOpenService.unavailableReferencedSourceIDs(in: ReferencedSourceStore(paths: paths))

        XCTAssertNil(sourceIDs)
        XCTAssertEqual(fixture.controller.activeLibraryContext, opened.context)
        let registryAfter = await fixture.registry.snapshot()
        XCTAssertEqual(registryAfter, registryBefore)
    }

    func testSuccessfulEmptySourceCheckIsDistinctFromFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("referenced")
        _ = try fixture.makeLibrary(at: root, mode: .referenced)
        let sourceIDs = await LibraryOpenService.unavailableReferencedSourceIDs(in: ReferencedSourceStore(paths: LibraryPaths(rootURL: root)))
        XCTAssertEqual(sourceIDs, [])
    }

    func testOpenCurrentLibraryThroughSymlinkKeepsExistingSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        _ = try fixture.makeLibrary(at: root, mode: .managed)
        let opened = try await fixture.openService.open(selectedURL: root)
        let sessionBefore = fixture.controller.activeSession
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)

        let reopened = try await fixture.openService.open(selectedURL: alias)

        XCTAssertTrue(fixture.controller.activeSession === sessionBefore)
        XCTAssertEqual(reopened.context, opened.context)
        XCTAssertFalse(reopened.didRegister)
        let registry = await fixture.registry.snapshot()
        XCTAssertEqual(registry.libraries.count, 1)
    }

    func testRootLeaseAcceptsBookmarkResolvingSymlinkToSameDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed)
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let context = LibraryContext(
            manifest: manifest, rootURL: alias,
            rootBookmarkData: try fixture.bookmarks.refreshBookmark(for: root), generation: 1
        )
        let lease = try LibraryRootAccessLease(context: context, resolver: fixture.bookmarks, requiresSecurityScope: true)
        lease.release()
        XCTAssertEqual(
            lease.rootURL.resolvingSymlinksInPath().standardizedFileURL.path,
            root.resolvingSymlinksInPath().standardizedFileURL.path
        )
        XCTAssertEqual(fixture.bookmarks.startCount, fixture.bookmarks.stopCount)
    }

    func testExplicitOpenRejectsStorageModeChangeForRegisteredIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed)
        let opened = try await fixture.openService.open(selectedURL: root)
        let registryBefore = await fixture.registry.snapshot()
        let changed = kmgccc_player.MusicLibraryManifest(libraryID: manifest.libraryID, displayName: "Changed", mode: .referenced)
        try changed.write(to: opened.context.paths.manifestURL)

        await XCTAssertThrowsErrorAsync(try await fixture.openService.open(selectedURL: root)) {
            XCTAssertEqual($0 as? LibraryOpenError, .reconnectModeMismatch(expected: .managed, actual: .referenced))
        }
        XCTAssertEqual(fixture.controller.activeLibraryContext, opened.context)
        let registryAfter = await fixture.registry.snapshot()
        XCTAssertEqual(registryAfter, registryBefore)
    }

    func testBusyOpenPathsDoNotInspectOrRepairLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: root)
        let registryBefore = await fixture.registry.snapshot()
        let settings = LibraryPaths(rootURL: root).librarySettingsURL
        try FileManager.default.removeItem(at: settings)
        try fixture.gate.acquire()
        defer { fixture.gate.release() }

        await XCTAssertThrowsErrorAsync(try await fixture.openService.open(selectedURL: root)) {
            XCTAssertEqual($0 as? LibraryOpenError, .transactionInProgress)
        }
        await XCTAssertThrowsErrorAsync(try await fixture.openService.activateRegisteredLibrary(id: manifest.libraryID)) {
            XCTAssertEqual($0 as? LibraryOpenError, .transactionInProgress)
        }
        await XCTAssertThrowsErrorAsync(try await fixture.openService.reconnectRegisteredLibrary(id: manifest.libraryID, selectedURL: root)) {
            XCTAssertEqual($0 as? LibraryOpenError, .transactionInProgress)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
        let registryAfter = await fixture.registry.snapshot()
        XCTAssertEqual(registryAfter, registryBefore)
    }

    func testActivationRejectsRootReplacedAfterInspection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let currentRoot = fixture.root.appendingPathComponent("current")
        _ = try fixture.makeLibrary(at: currentRoot, mode: .managed)
        let current = try await fixture.openService.open(selectedURL: currentRoot)
        let targetRoot = fixture.root.appendingPathComponent("target")
        _ = try fixture.makeLibrary(at: targetRoot, mode: .managed)
        let inspection = try await fixture.openService.inspect(selectedURL: targetRoot)
        let registryBefore = await fixture.registry.snapshot()
        let replacement = kmgccc_player.MusicLibraryManifest(displayName: "Replacement", mode: .managed)
        try replacement.write(to: inspection.context.paths.manifestURL)

        await XCTAssertThrowsErrorAsync(try await fixture.openService.commitActivation(inspection)) {
            XCTAssertEqual($0 as? LibraryOpenError, .libraryChanged)
        }
        XCTAssertEqual(fixture.controller.activeLibraryContext, current.context)
        let registryAfter = await fixture.registry.snapshot()
        XCTAssertEqual(registryAfter, registryBefore)
        XCTAssertEqual(try kmgccc_player.MusicLibraryManifest.read(from: inspection.context.paths.manifestURL).libraryID, replacement.libraryID)
    }

    func testActivationRejectsBookmarkRedirectedAfterInspection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let targetRoot = fixture.root.appendingPathComponent("target")
        _ = try fixture.makeLibrary(at: targetRoot, mode: .managed)
        let inspection = try await fixture.openService.inspect(selectedURL: targetRoot)
        let otherRoot = fixture.root.appendingPathComponent("other")
        _ = try fixture.makeLibrary(at: otherRoot, mode: .managed)
        fixture.bookmarks.redirect(inspection.context.rootBookmarkData, to: otherRoot)

        await XCTAssertThrowsErrorAsync(try await fixture.openService.commitActivation(inspection)) {
            XCTAssertEqual($0 as? LibraryOpenError, .libraryChanged)
        }
        XCTAssertNil(fixture.controller.activeLibraryContext)
        let registry = await fixture.registry.snapshot()
        XCTAssertTrue(registry.libraries.isEmpty)
    }

    func testReopeningInspectedContextRejectsDifferentLibraryAtSamePath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        _ = try fixture.makeLibrary(at: root, mode: .managed)
        let inspected = try await fixture.openService.inspect(selectedURL: root)
        let replacement = kmgccc_player.MusicLibraryManifest(displayName: "Replacement", mode: .managed)
        try replacement.write(to: inspected.context.paths.manifestURL)
        // Identity must survive the UI handoff, which performs a fresh open.
        await XCTAssertThrowsErrorAsync(try await fixture.openService.open(selectedURL: root, expectedContext: inspected.context)) {
            XCTAssertEqual($0 as? LibraryOpenError, .libraryChanged)
        }
        XCTAssertNil(fixture.controller.activeSession)
        let registry = await fixture.registry.snapshot()
        XCTAssertTrue(registry.libraries.isEmpty)
    }

    func testRegistryFailureBeforeSwitchKeepsExistingSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let oldRoot = fixture.root.appendingPathComponent("old")
        _ = try fixture.makeLibrary(at: oldRoot, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: oldRoot)
        let sessionBefore = fixture.controller.activeSession
        let registryBefore = await fixture.registry.snapshot()
        let targetRoot = fixture.root.appendingPathComponent("target")
        _ = try fixture.makeLibrary(at: targetRoot, mode: .managed)
        fixture.registryFailure.arm()

        await XCTAssertThrowsErrorAsync(try await fixture.openService.open(selectedURL: targetRoot)) {
            XCTAssertEqual($0 as? LibraryOpenError, .registryCommitFailed)
        }
        XCTAssertTrue(fixture.controller.activeSession === sessionBefore)
        let registryAfter = await fixture.registry.snapshot()
        XCTAssertEqual(registryAfter, registryBefore)
    }

    func testRegisteredActivationFailureRestoresSessionAndRegistry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let oldRoot = fixture.root.appendingPathComponent("old")
        _ = try fixture.makeLibrary(at: oldRoot, mode: .managed)
        let old = try await fixture.openService.open(selectedURL: oldRoot)
        let targetRoot = fixture.root.appendingPathComponent("target")
        let target = try fixture.makeLibrary(at: targetRoot, mode: .managed)
        try await fixture.registerWithoutActivation(root: targetRoot, manifest: target)
        let registryBefore = await fixture.registry.snapshot()
        fixture.factory.failNextLoadForNewRoot = true

        await XCTAssertThrowsErrorAsync(try await fixture.openService.activateRegisteredLibrary(id: target.libraryID)) {
            XCTAssertEqual($0 as? LibraryOpenError, .activationFailed)
        }
        XCTAssertEqual(fixture.controller.activeLibraryContext, old.context)
        let registryAfter = await fixture.registry.snapshot()
        XCTAssertEqual(registryAfter, registryBefore)
    }

    func testFailedSessionRecoveryStillRollsBackRegistry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let oldRoot = fixture.root.appendingPathComponent("old")
        _ = try fixture.makeLibrary(at: oldRoot, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: oldRoot)
        let registryBefore = await fixture.registry.snapshot()
        let targetRoot = fixture.root.appendingPathComponent("target")
        _ = try fixture.makeLibrary(at: targetRoot, mode: .managed)
        fixture.factory.failingLoadRoots = [oldRoot, targetRoot]

        await XCTAssertThrowsErrorAsync(try await fixture.openService.open(selectedURL: targetRoot)) {
            XCTAssertEqual($0 as? LibraryOpenError, .recoveryFailed)
        }
        XCTAssertNil(fixture.controller.activeSession)
        let registryAfter = await fixture.registry.snapshot()
        XCTAssertEqual(registryAfter, registryBefore)
    }

    func testActivePointerAlreadyCommittedDoesNotWriteAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: root)
        fixture.registryFailure.arm()

        try await fixture.registry.setActiveLibrary(id: manifest.libraryID, manifestMode: .managed)
        // The injected failure remains for the next real write.
        await XCTAssertThrowsErrorAsync(try await fixture.registry.updateDisplayName(libraryID: manifest.libraryID, displayName: "Changed")) {
            XCTAssertTrue($0 is TestError)
        }
    }

    func testLibraryOpenMessagesDistinguishValidationActivationAndRecovery() {
        let invalid = LibraryOpenFailure.message(for: LibraryOpenError.invalidManifest)
        let activation = LibraryOpenFailure.message(for: LibraryOpenError.activationFailed)
        let recovery = LibraryOpenFailure.message(for: LibraryOpenError.recoveryFailed)
        let registry = LibraryOpenFailure.message(for: LibraryOpenError.registryCommitFailed)
        XCTAssertTrue(invalid.contains("格式"))
        XCTAssertTrue(activation.contains("加载失败"))
        XCTAssertTrue(recovery.contains("恢复失败"))
        XCTAssertTrue(registry.contains("保存"))
        XCTAssertEqual(Set([invalid, activation, recovery, registry]).count, 4)
        let writerError = LibraryWriterLeaseError.libraryInUse(URL(fileURLWithPath: "/library"))
        XCTAssertEqual(LibraryOpenFailure.message(for: writerError), writerError.localizedDescription)
    }

    func testStartupDoesNotReplaceLibraryForBusyCancelledOrRegistryFailure() {
        let errors: [any Error] = [
            LibraryOpenError.transactionInProgress,
            LibraryLifecycleTransactionGateError.transactionInProgress,
            LibraryOpenError.registryCommitFailed,
            LibraryOpenError.recoveryFailed,
            CancellationError(),
            LibraryWriterLeaseError.libraryInUse(URL(fileURLWithPath: "/library"))
        ]
        for error in errors {
            XCTAssertFalse(LibraryStartupFailurePolicy.permitsFactoryDefaultFallback(after: error), "\(error)")
        }
        XCTAssertTrue(LibraryStartupFailurePolicy.permitsFactoryDefaultFallback(after: LibraryOpenError.invalidManifest))
    }

    func testCreationActivationFailureRetainsPublishedDestinationAndRestoresRegistry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("parent")
        fixture.factory.failNextLoadForNewRoot = true

        await XCTAssertThrowsErrorAsync(
            try await fixture.creationService().create(mode: .managed, parentURL: parent, displayName: "New")
        ) { XCTAssertEqual($0 as? LibraryCreationError, .sessionActivationFailed) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.appendingPathComponent("kmgccc_player Library - New").path))
        let registry = await fixture.registry.snapshot()
        XCTAssertTrue(registry.libraries.isEmpty)
        XCTAssertNil(fixture.controller.activeLibraryContext)
    }

    func testCreationFailurePreservesDestinationReplacedByAnotherLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("parent")
        let destination = parent.appendingPathComponent("kmgccc_player Library - New")
        let replacement = kmgccc_player.MusicLibraryManifest(displayName: "Replacement", mode: .managed)
        fixture.factory.beforeNextMake = { context in
            try replacement.write(to: context.paths.manifestURL)
            try Data("keep".utf8).write(to: context.rootURL.appendingPathComponent("keep.txt"))
        }
        fixture.factory.failNextLoadForNewRoot = true

        await XCTAssertThrowsErrorAsync(try await fixture.creationService().create(mode: .managed, parentURL: parent, displayName: "New")) {
            XCTAssertEqual($0 as? LibraryCreationError, .sessionActivationFailed)
        }
        XCTAssertEqual(try kmgccc_player.MusicLibraryManifest.read(from: LibraryPaths(rootURL: destination).manifestURL).libraryID, replacement.libraryID)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("keep.txt"), encoding: .utf8), "keep")
        XCTAssertNil(fixture.controller.activeSession)
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

    func testRelocationValidationDetectsSameSizeChangedContent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed)
        let audio = root.appendingPathComponent("audio.bin")
        try Data("first".utf8).write(to: audio)
        let fileOperator = ProductionLibraryLifecycleFileOperator()
        let authority = try await fileOperator.captureRelocationAuthority(at: root)
        try Data("other".utf8).write(to: audio)
        await XCTAssertThrowsErrorAsync(
            try await fileOperator.validateRelocation(at: root, expectedAuthority: authority, expectedID: manifest.libraryID, expectedMode: manifest.mode)
        ) { XCTAssertEqual($0 as? LibraryRelocationError, .validationFailed) }
    }

    func testRelocationValidationDetectsChangedHiddenFilesAndSymlinks() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed)
        let hidden = root.appendingPathComponent(".user-data")
        try Data("first".utf8).write(to: hidden)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "first-target")
        let fileOperator = ProductionLibraryLifecycleFileOperator()
        let authority = try await fileOperator.captureRelocationAuthority(at: root)
        try Data("other".utf8).write(to: hidden)
        await XCTAssertThrowsErrorAsync(
            try await fileOperator.validateRelocation(at: root, expectedAuthority: authority, expectedID: manifest.libraryID, expectedMode: manifest.mode)
        ) { XCTAssertEqual($0 as? LibraryRelocationError, .validationFailed) }
        try Data("first".utf8).write(to: hidden)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "other-target")
        await XCTAssertThrowsErrorAsync(
            try await fileOperator.validateRelocation(at: root, expectedAuthority: authority, expectedID: manifest.libraryID, expectedMode: manifest.mode)
        ) { XCTAssertEqual($0 as? LibraryRelocationError, .validationFailed) }
    }

    func testLegacyRelocationSnapshotWithoutDigestsDecodes() throws {
        let data = Data(#"{"relativeAuthorityFiles":[],"fileCount":0}"#.utf8)
        let snapshot = try JSONDecoder().decode(LibraryRelocationAuthoritySnapshot.self, from: data)
        XCTAssertNil(snapshot.fileDigests)
        XCTAssertEqual(snapshot.fileCount, 0)
    }

    func testRelocationSnapshotRejectsSpecialFilesWithoutReadingThem() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        _ = try fixture.makeLibrary(at: root, mode: .managed)
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
        let fileOperator = ProductionLibraryLifecycleFileOperator()
        await XCTAssertThrowsErrorAsync(try await fileOperator.captureRelocationAuthority(at: root)) {
            XCTAssertEqual($0 as? LibraryRelocationError, .validationFailed)
        }
    }

    func testSQLiteValidationRejectsLargeOutputAndTimesOut() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed)
        try Data().write(to: root.appendingPathComponent("test.sqlite"))
        let executable = fixture.root.appendingPathComponent("sqlite-check")
        func install(_ body: String) throws {
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        try install("while :; do printf 'integrity error\\n'; done")
        let noisy = ProductionLibraryLifecycleFileOperator(sqliteExecutableURL: executable, sqliteCheckTimeout: 5)
        let authority = try await noisy.captureRelocationAuthority(at: root)
        let clock = ContinuousClock()
        let noisyStart = clock.now
        await XCTAssertThrowsErrorAsync(
            try await noisy.validateRelocation(at: root, expectedAuthority: authority, expectedID: manifest.libraryID, expectedMode: manifest.mode)
        ) { XCTAssertEqual($0 as? LibraryRelocationError, .validationFailed) }
        XCTAssertLessThan(noisyStart.duration(to: clock.now), .seconds(3))

        try install("while :; do :; done")
        let hung = ProductionLibraryLifecycleFileOperator(sqliteExecutableURL: executable, sqliteCheckTimeout: 0.2)
        let start = clock.now
        await XCTAssertThrowsErrorAsync(
            try await hung.validateRelocation(at: root, expectedAuthority: authority, expectedID: manifest.libraryID, expectedMode: manifest.mode)
        ) { XCTAssertEqual($0 as? LibraryRelocationError, .validationFailed) }
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(3))
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
        fixture.registryFailure.arm()

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

    func testCrossVolumePreparedReplayPreservesOrphanForRecovery() async throws {
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertEqual(
            service.preservedRecoveryCopies.map { $0.resolvingSymlinksInPath().standardizedFileURL.path },
            [staging.resolvingSymlinksInPath().standardizedFileURL.path]
        )
    }

    func testRelocationReplayFinishesRegistryCommittedPhaseAfterRelaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        let manifest = try fixture.makeLibrary(at: source, mode: .managed)
        try await fixture.registerWithoutActivation(root: source, manifest: manifest)
        let before = await fixture.registry.snapshot()
        let staleRegistry = try MusicLibraryRegistryStore(fileURL: fixture.registry.fileURL)
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
        _ = try await fileOperator.relocate(from: source, toStaging: staging)
        // Simulate a cross-volume move whose original path was reused.
        intent.transfer = .copiedAcrossVolumes
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let replacement = source.appendingPathComponent("new-user-file")
        try Data("keep".utf8).write(to: replacement)
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
        let unrelated = fixture.root.appendingPathComponent("unrelated")
        let unrelatedManifest = try fixture.makeLibrary(at: unrelated, mode: .referenced)
        try await fixture.registerWithoutActivation(root: unrelated, manifest: unrelatedManifest)

        let service = LibraryRelocationService(
            registryStore: staleRegistry,
            sessionController: fixture.controller,
            sessionValidator: LibrarySessionFactoryValidator(factory: fixture.factory),
            bookmarkResolver: fixture.bookmarks,
            recycler: fixture.recycler,
            intentURL: journal
        )
        let didReplay = try await service.replayPendingRepair()
        XCTAssertTrue(didReplay)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: replacement), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        let registryAfter = await fixture.registry.snapshot()
        XCTAssertEqual(registryAfter.library(id: manifest.libraryID)?.lastKnownPath, destination.path)
        XCTAssertNotNil(registryAfter.library(id: unrelatedManifest.libraryID))
        let replayRegistry = await staleRegistry.snapshot()
        XCTAssertEqual(replayRegistry.library(id: manifest.libraryID)?.lastKnownPath, destination.path)
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

    func testTrashedDefaultIsReplacedWithEmptyExactRootAndPreservesCustomLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("Music")
        let oldRoot = parent.appendingPathComponent(LibraryPaths.rootDirectoryName)
        let old = try fixture.makeLibrary(at: oldRoot, mode: .referenced)
        let opened = try await fixture.openService.open(selectedURL: oldRoot)
        let oldBookmark = opened.context.rootBookmarkData
        let customRoot = parent.appendingPathComponent("kmgccc_player Library - Custom")
        let custom = try fixture.makeLibrary(at: customRoot, mode: .managed)
        try await fixture.registerWithoutActivation(root: customRoot, manifest: custom)
        let customManifestBefore = try Data(contentsOf: LibraryPaths(rootURL: customRoot).manifestURL)
        let trashRoot = fixture.root.appendingPathComponent(".Trash").appendingPathComponent(LibraryPaths.rootDirectoryName)
        try FileManager.default.createDirectory(at: trashRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldRoot, to: trashRoot)
        fixture.bookmarks.redirect(oldBookmark, to: trashRoot)
        // Reproduce an older build that already persisted the followed Trash path.
        try await fixture.registry.updateBookmark(
            libraryID: old.libraryID,
            bookmarkData: oldBookmark,
            lastKnownPath: trashRoot.path,
            modeProjection: old.mode
        )
        let trashedManifestBefore = try Data(contentsOf: LibraryPaths(rootURL: trashRoot).manifestURL)
        let resolver = LibraryStartupContextResolver(registryStore: fixture.registry, bookmarkResolver: fixture.bookmarks)

        let resolution = await resolver.resolve()

        XCTAssertEqual(resolution, .noActive)
        var registry = await fixture.registry.snapshot()
        XCTAssertNil(registry.library(id: old.libraryID))
        XCTAssertEqual(registry.pendingFactoryDefaultReplacement, true)
        XCTAssertNotNil(registry.library(id: custom.libraryID))
        let result = try await fixture.creationService().create(
            mode: .referenced,
            parentURL: parent,
            displayName: "音乐资料库",
            factoryDefaultRoot: true,
            allowAlternateDestinationWhenOccupied: true
        )
        guard case .created(let replacement, _) = result else { return XCTFail("Expected an empty replacement") }
        XCTAssertEqual(replacement.rootURL.path, oldRoot.standardizedFileURL.path)
        XCTAssertNotEqual(replacement.id, old.libraryID)
        XCTAssertNotEqual(replacement.rootBookmarkData, oldBookmark)
        XCTAssertEqual(try fixture.bookmarks.resolve(oldBookmark).url.path, trashRoot.path)
        XCTAssertEqual(try fixture.bookmarks.resolve(replacement.rootBookmarkData).url.path, replacement.rootURL.path)
        XCTAssertEqual(replacement.mode, .referenced)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: replacement.paths.tracksRootURL.path).isEmpty)
        XCTAssertEqual(try MusicLibraryManifest.read(from: replacement.paths.manifestURL).libraryID, replacement.id)
        try await fixture.registry.completeFactoryDefaultReplacement(libraryID: replacement.id, defaultRootURL: oldRoot)
        registry = await fixture.registry.snapshot()
        XCTAssertEqual(registry.activeLibraryID, replacement.id)
        XCTAssertNil(registry.pendingFactoryDefaultReplacement)
        XCTAssertEqual(try Data(contentsOf: LibraryPaths(rootURL: customRoot).manifestURL), customManifestBefore)
        XCTAssertEqual(try Data(contentsOf: LibraryPaths(rootURL: trashRoot).manifestURL), trashedManifestBefore)
    }

    func testFactoryDefaultCreationNeverSelectsAnAlternateOccupiedRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("Music")
        let occupiedRoot = parent.appendingPathComponent(LibraryPaths.rootDirectoryName)
        try FileManager.default.createDirectory(at: occupiedRoot, withIntermediateDirectories: true)
        let unknownFile = occupiedRoot.appendingPathComponent("keep.txt")
        let original = Data("user content".utf8)
        try original.write(to: unknownFile)

        await XCTAssertThrowsErrorAsync(try await fixture.creationService().create(
            mode: .referenced,
            parentURL: parent,
            displayName: "音乐资料库",
            factoryDefaultRoot: true,
            allowAlternateDestinationWhenOccupied: true
        )) { XCTAssertEqual($0 as? LibraryCreationError, .destinationContainsUnknownItems) }

        XCTAssertEqual(try Data(contentsOf: unknownFile), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [LibraryPaths.rootDirectoryName])
        let registry = await fixture.registry.snapshot()
        XCTAssertTrue(registry.libraries.isEmpty)
    }

    func testDeletingActiveDefaultRequestsReplacementInsteadOfCustomSuccessor() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("default")
        let original = try fixture.makeLibrary(at: root, mode: .referenced)
        _ = try await fixture.openService.open(selectedURL: root)
        try await fixture.registry.updateBookmark(
            libraryID: original.libraryID,
            bookmarkData: Data(root.path.utf8),
            lastKnownPath: LibraryLocationStore.defaultLibraryRootURL.path,
            modeProjection: original.mode
        )
        let customRoot = fixture.root.appendingPathComponent("custom")
        let custom = try fixture.makeLibrary(at: customRoot, mode: .managed)
        try await fixture.registerWithoutActivation(root: customRoot, manifest: custom)

        let action = try await fixture.removalService().moveToTrash(libraryID: original.libraryID)

        XCTAssertEqual(action, .chooseLibrary)
        XCTAssertNil(fixture.controller.activeLibraryContext)
        let registry = await fixture.registry.snapshot()
        XCTAssertNil(registry.library(id: original.libraryID))
        XCTAssertNotNil(registry.library(id: custom.libraryID))
        XCTAssertEqual(registry.pendingFactoryDefaultReplacement, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: customRoot.path))
    }

    func testTrashReconciliationPreservesUnavailableCustomRegistration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("offline-custom")
        let manifest = try fixture.makeLibrary(at: root, mode: .managed)
        try await fixture.registerWithoutActivation(root: root, manifest: manifest)
        try FileManager.default.removeItem(at: root)
        fixture.bookmarks.allowsAccess = false
        let resolver = LibraryStartupContextResolver(registryStore: fixture.registry, bookmarkResolver: fixture.bookmarks)

        let removed = await resolver.removeTrashedLibraries()

        XCTAssertTrue(removed.isEmpty)
        let registry = await fixture.registry.snapshot()
        XCTAssertNotNil(registry.library(id: manifest.libraryID))
        XCTAssertNil(registry.pendingFactoryDefaultReplacement)
    }

    func testInactiveDefaultInTrashRequiresReplacementWhileCustomLibraryIsActive() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let trashRoot = fixture.root.appendingPathComponent(".Trash").appendingPathComponent(LibraryPaths.rootDirectoryName)
        let old = try fixture.makeLibrary(at: trashRoot, mode: .referenced)
        try await fixture.registerWithoutActivation(root: trashRoot, manifest: old)
        let customRoot = fixture.root.appendingPathComponent("custom")
        let custom = try fixture.makeLibrary(at: customRoot, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: customRoot)
        let customManifestBefore = try Data(contentsOf: LibraryPaths(rootURL: customRoot).manifestURL)

        let resolution = await LibraryStartupContextResolver(
            registryStore: fixture.registry,
            bookmarkResolver: fixture.bookmarks
        ).resolve()

        guard case .context(let selected) = resolution else {
            return XCTFail("Expected the selected custom library to remain active")
        }
        XCTAssertEqual(selected.id, custom.libraryID)
        let registry = await fixture.registry.snapshot()
        XCTAssertNil(registry.library(id: old.libraryID))
        XCTAssertEqual(registry.activeLibraryID, custom.libraryID)
        XCTAssertEqual(registry.pendingFactoryDefaultReplacement, true)
        XCTAssertEqual(try Data(contentsOf: LibraryPaths(rootURL: customRoot).manifestURL), customManifestBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashRoot.path))
    }

    func testRelaunchPrefersSelectedLegacyLibraryWithPendingDefaultReplacement() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let customRoot = fixture.root.appendingPathComponent("custom")
        let custom = try fixture.makeLibrary(at: customRoot, mode: .referenced)
        let manifestURL = LibraryPaths(rootURL: customRoot).manifestURL
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        object["createdAt"] = "2026-01-02T03:04:05.123456Z"
        object["updatedAt"] = "2026-01-02T03:04:05.123456Z"
        let legacyManifestData = try JSONSerialization.data(withJSONObject: object)
        try legacyManifestData.write(to: manifestURL)
        try await fixture.registerWithoutActivation(root: customRoot, manifest: custom)
        let defaultRoot = fixture.root.appendingPathComponent(LibraryPaths.rootDirectoryName)
        let fallback = try fixture.makeLibrary(at: defaultRoot, mode: .referenced)
        try await fixture.registerWithoutActivation(root: defaultRoot, manifest: fallback)
        try await fixture.registry.setActiveLibrary(id: custom.libraryID, manifestMode: custom.mode)
        var saved = await fixture.registry.snapshot()
        saved.pendingFactoryDefaultReplacement = true
        try await fixture.registry.replaceSnapshot(saved)

        let registryURL = await fixture.registry.fileURL
        let relaunchedRegistry = try MusicLibraryRegistryStore(fileURL: registryURL)
        let resolution = await LibraryStartupContextResolver(
            registryStore: relaunchedRegistry, bookmarkResolver: fixture.bookmarks
        ).resolve()

        guard case .context(let selected) = resolution else {
            return XCTFail("Expected the persisted selected library to open despite deferred default maintenance")
        }
        XCTAssertEqual(selected.id, custom.libraryID)
        XCTAssertEqual(
            selected.rootURL.resolvingSymlinksInPath().standardizedFileURL.path,
            customRoot.resolvingSymlinksInPath().standardizedFileURL.path
        )
        let after = await relaunchedRegistry.snapshot()
        XCTAssertEqual(after.activeLibraryID, custom.libraryID)
        XCTAssertEqual(after.libraries.count, 2)
        XCTAssertEqual(try Data(contentsOf: manifestURL), legacyManifestData)
        try await relaunchedRegistry.setActiveLibrary(id: selected.id, manifestMode: selected.mode)
        let activated = await relaunchedRegistry.snapshot()
        XCTAssertNil(activated.pendingFactoryDefaultReplacement)
    }

    func testManifestDateCompatibilityStillRejectsMalformedDates() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        _ = try fixture.makeLibrary(at: root, mode: .managed)
        let url = LibraryPaths(rootURL: root).manifestURL
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["createdAt"] = "invalid-date"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try MusicLibraryManifest.read(from: url))
    }

    func testDeletingInactiveDefaultRequestsReplacementAndPreservesActiveCustomLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let defaultRoot = fixture.root.appendingPathComponent("default")
        let old = try fixture.makeLibrary(at: defaultRoot, mode: .referenced)
        try await fixture.registerWithoutActivation(root: defaultRoot, manifest: old)
        try await fixture.registry.updateBookmark(
            libraryID: old.libraryID,
            bookmarkData: Data(defaultRoot.path.utf8),
            lastKnownPath: LibraryLocationStore.defaultLibraryRootURL.path,
            modeProjection: old.mode
        )
        let customRoot = fixture.root.appendingPathComponent("custom")
        let custom = try fixture.makeLibrary(at: customRoot, mode: .managed)
        _ = try await fixture.openService.open(selectedURL: customRoot)

        let action = try await fixture.removalService().moveToTrash(libraryID: old.libraryID)

        XCTAssertEqual(action, .chooseLibrary)
        XCTAssertEqual(fixture.controller.activeLibraryContext?.id, custom.libraryID)
        var registry = await fixture.registry.snapshot()
        XCTAssertEqual(registry.pendingFactoryDefaultReplacement, true)
        XCTAssertNil(registry.library(id: old.libraryID))
        let parent = fixture.root.appendingPathComponent("Music")
        let result = try await fixture.creationService().create(
            mode: .referenced,
            parentURL: parent,
            displayName: "音乐资料库",
            factoryDefaultRoot: true
        )
        guard case .created(let replacement, _) = result else { return XCTFail("Expected replacement") }
        XCTAssertEqual(fixture.controller.activeLibraryContext?.id, replacement.id)
        try await fixture.registry.completeFactoryDefaultReplacement(
            libraryID: replacement.id,
            defaultRootURL: parent.appendingPathComponent(LibraryPaths.rootDirectoryName)
        )
        registry = await fixture.registry.snapshot()
        XCTAssertNil(registry.pendingFactoryDefaultReplacement)
        XCTAssertNotNil(registry.library(id: custom.libraryID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: customRoot.path))
    }

    func testFlushPolicySkipsMovedOrReplacedRootsButReportsManifestErrors() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("library")
        let manifest = try fixture.makeLibrary(at: root, mode: .referenced)
        let context = LibraryContext(manifest: manifest, rootURL: root, rootBookmarkData: Data(), generation: 1)
        XCTAssertTrue(try LibraryRootLocationPolicy.canFlush(context))

        try Data("damaged manifest".utf8).write(to: context.paths.manifestURL)
        XCTAssertThrowsError(try LibraryRootLocationPolicy.canFlush(context))

        try FileManager.default.removeItem(at: context.paths.manifestURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertThrowsError(try LibraryRootLocationPolicy.canFlush(context))

        let replacement = MusicLibraryManifest(displayName: "Replacement", mode: .referenced)
        try replacement.write(to: context.paths.manifestURL)
        let replacementData = try Data(contentsOf: context.paths.manifestURL)
        XCTAssertFalse(try LibraryRootLocationPolicy.canFlush(context))

        _ = try context.rootURL.resourceValues(forKeys: [.isDirectoryKey])
        let movedRoot = fixture.root.appendingPathComponent("moved-library")
        try FileManager.default.moveItem(at: root, to: movedRoot)
        XCTAssertFalse(try LibraryRootLocationPolicy.canFlush(context))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(try Data(contentsOf: LibraryPaths(rootURL: movedRoot).manifestURL), replacementData)

        _ = try fixture.makeLibrary(at: root, mode: .referenced)
        XCTAssertFalse(try LibraryRootLocationPolicy.canFlush(context))
        _ = try context.rootURL.resourceValues(forKeys: [.isDirectoryKey])
        try FileManager.default.removeItem(at: root)
        XCTAssertFalse(try LibraryRootLocationPolicy.canFlush(context))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let trashContext = LibraryContext(
            manifest: manifest,
            rootURL: fixture.root.appendingPathComponent(".Trash/library"),
            rootBookmarkData: Data(),
            generation: 1
        )
        XCTAssertFalse(try LibraryRootLocationPolicy.canFlush(trashContext))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashContext.rootURL.path))
    }

    func testExplicitOpenRejectsTrashBeforeRepairingScaffolding() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent(".Trashes/501/custom")
        _ = try fixture.makeLibrary(at: root, mode: .managed)
        let settingsURL = LibraryPaths(rootURL: root).librarySettingsURL
        try FileManager.default.removeItem(at: settingsURL)

        await XCTAssertThrowsErrorAsync(try await fixture.openService.open(selectedURL: root)) {
            XCTAssertEqual($0 as? LibraryOpenError, .libraryNotFound)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
        XCTAssertNil(fixture.controller.activeLibraryContext)
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

    func testStartupActiveBookmarkFailureFallsBackToHealthyLibrary() async throws {
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
        guard case .context(let context) = resolution else {
            return XCTFail("Expected the healthy registered library to be selected")
        }
        XCTAssertEqual(context.id, healthy.libraryID)
        XCTAssertEqual(fixture.bookmarks.startCount, startsBefore + 1)
    }

    func testStartupActiveManifestMismatchFallsBackToHealthyLibrary() async throws {
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
        guard case .context(let context) = resolution else {
            return XCTFail("Expected the healthy registered library to be selected")
        }
        XCTAssertEqual(context.id, healthy.libraryID)
        XCTAssertEqual(fixture.bookmarks.startCount, startsBefore + 2)
    }

    func testStartupWithNilActiveAutomaticallyOpensRecentLibrary() async throws {
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
        guard case .context(let context) = resolution else {
            return XCTFail("Expected the recent registered library to be selected")
        }
        XCTAssertEqual(context.id, manifest.libraryID)
        XCTAssertEqual(fixture.bookmarks.startCount, startsBefore + 1)
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
    private struct State {
        var isStale = false
        var allowsAccess = true
        var failNextRefresh = false
        var redirectedBookmarks: [Data: URL] = [:]
        var bookmarkRoots: [Data: URL] = [:]
        var startCount = 0
        var stopCount = 0
        var refreshCount = 0
    }

    private let lock = NSLock()
    private var state = State()
    var isStale: Bool {
        get { lock.withLock { state.isStale } }
        set { lock.withLock { state.isStale = newValue } }
    }
    var allowsAccess: Bool {
        get { lock.withLock { state.allowsAccess } }
        set { lock.withLock { state.allowsAccess = newValue } }
    }
    var failNextRefresh: Bool {
        get { lock.withLock { state.failNextRefresh } }
        set { lock.withLock { state.failNextRefresh = newValue } }
    }
    var startCount: Int { lock.withLock { state.startCount } }
    var stopCount: Int { lock.withLock { state.stopCount } }
    var refreshCount: Int { lock.withLock { state.refreshCount } }

    func redirect(_ bookmark: Data, to rootURL: URL) {
        lock.withLock { state.redirectedBookmarks[bookmark] = rootURL }
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        try lock.withLock {
            if let root = state.redirectedBookmarks[data] ?? state.bookmarkRoots[data] { return (root, state.isStale) }
            guard let path = String(data: data, encoding: .utf8) else { throw TestError.expected }
            return (URL(fileURLWithPath: path, isDirectory: true), state.isStale)
        }
    }
    func refreshBookmark(for url: URL) throws -> Data {
        try lock.withLock {
            state.refreshCount += 1
            if state.failNextRefresh { state.failNextRefresh = false; throw TestError.expected }
            // A fresh bookmark belongs to this root, even if an earlier root at
            // the same path has moved to the Trash.
            let bookmark = Data(UUID().uuidString.utf8)
            state.bookmarkRoots[bookmark] = url.standardizedFileURL
            return bookmark
        }
    }
    func startAccessing(_ url: URL) -> Bool {
        lock.withLock {
            state.startCount += 1
            return state.allowsAccess
        }
    }
    func stopAccessing(_ url: URL) {
        lock.withLock { state.stopCount += 1 }
    }
}

@MainActor
private final class LifecycleTestSessionFactory: kmgccc_player.LibrarySessionBuilding {
    var failNextLoadForNewRoot = false
    var failingLoadRoots: Set<URL> = []
    var sabotageRegistryOnNextLoad: URL?
    var beforeNextMake: ((kmgccc_player.LibraryContext) throws -> Void)?
    private var lastLoadedRoot: URL?

    func makeSession(for context: kmgccc_player.LibraryContext) async throws -> any kmgccc_player.LibrarySessionLifecycle {
        let beforeMake = beforeNextMake
        beforeNextMake = nil
        try beforeMake?(context)
        let canonicalRoot = context.rootURL.resolvingSymlinksInPath().standardizedFileURL
        let canonicalFailureRoots = Set(failingLoadRoots.map {
            $0.resolvingSymlinksInPath().standardizedFileURL
        })
        let shouldFail = canonicalFailureRoots.contains(canonicalRoot)
            || (failNextLoadForNewRoot && canonicalRoot != lastLoadedRoot?
                .resolvingSymlinksInPath().standardizedFileURL)
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

/// Regression: zero tracks is not proof of an orphan. An incomplete scan can
/// hide every track of an artist or album whose folder still holds user-edited
/// metadata, so only entries the sync flagged as orphaned and free of user
/// content may be removed.
@MainActor
final class LibraryMetadataOrphanCleanupTests: XCTestCase {
    func testCleanupRemovesOnlyPlainOrphans() {
        let editedArtist = makeArtist(hasUserEditedContent: true)
        let plainArtist = makeArtist()
        let editedAlbum = makeAlbum(hasUserEditedContent: true)
        let plainAlbum = makeAlbum()

        let report = LibraryMaintenanceService().cleanupOrphanMetadataEntries(
            artistEntries: [editedArtist, plainArtist],
            albumEntries: [editedAlbum, plainAlbum],
            reason: "regressionTest"
        )

        XCTAssertEqual(report.deletedArtistIDs, [plainArtist.id])
        XCTAssertEqual(report.deletedAlbumIDs, [plainAlbum.id])
    }

    func testCleanupKeepsZeroTrackEntriesThatAreNotOrphans() {
        let artist = makeArtist(isOrphaned: false)
        let album = makeAlbum(isOrphaned: false)

        let report = LibraryMaintenanceService().cleanupOrphanMetadataEntries(
            artistEntries: [artist],
            albumEntries: [album],
            reason: "regressionTest"
        )

        XCTAssertTrue(report.deletedArtistIDs.isEmpty)
        XCTAssertTrue(report.deletedAlbumIDs.isEmpty)
    }

    private func makeArtist(
        isOrphaned: Bool = true,
        hasUserEditedContent: Bool = false
    ) -> ArtistEntry {
        ArtistEntry(
            id: UUID(),
            canonicalName: "artist-\(UUID().uuidString)",
            displayName: "Artist",
            createdAt: Date(),
            updatedAt: Date(),
            trackCount: 0,
            albumCount: 0,
            totalDuration: 0,
            isOrphaned: isOrphaned,
            hasUserEditedContent: hasUserEditedContent
        )
    }

    private func makeAlbum(
        isOrphaned: Bool = true,
        hasUserEditedContent: Bool = false
    ) -> AlbumEntry {
        AlbumEntry(
            id: UUID(),
            canonicalKey: "album-\(UUID().uuidString)",
            displayTitle: "Album",
            primaryArtistCanonicalName: "artist",
            primaryArtistDisplayName: "Artist",
            createdAt: Date(),
            updatedAt: Date(),
            trackCount: 0,
            totalDuration: 0,
            isOrphaned: isOrphaned,
            hasUserEditedContent: hasUserEditedContent
        )
    }
}

/// Read-only repair inspection and the explicit quarantine action that moves
/// provably broken records into the library's Recovery folder.
@MainActor
final class LibraryRepairQuarantineTests: XCTestCase {
    func testInspectionAggregatesSourceAndJournalFailures() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try makeValidSource(in: fixture.paths)
        let brokenSourceID = UUID()
        try FileManager.default.createDirectory(
            at: fixture.paths.sourceRootURL(for: brokenSourceID),
            withIntermediateDirectories: true
        )
        let pendingURL = fixture.paths.pendingTransactionsRootURL.appendingPathComponent("broken.json")
        try Data("not json".utf8).write(to: pendingURL)

        let report = await LibraryRepairInspector.inspect(rootURL: fixture.paths.rootURL)

        XCTAssertEqual(report.libraryID, fixture.manifest.libraryID)
        XCTAssertTrue(report.issues.contains {
            $0.kind == .source
                && $0.path.resolvingSymlinksInPath().standardizedFileURL.path
                    == fixture.paths.sourceDescriptorURL(for: brokenSourceID)
                        .resolvingSymlinksInPath().standardizedFileURL.path
        }, "source issue missing: \(report.issues)")
        XCTAssertTrue(report.issues.contains {
            $0.kind == .transaction
                && $0.path.resolvingSymlinksInPath().standardizedFileURL.path
                    == pendingURL.resolvingSymlinksInPath().standardizedFileURL.path
        }, "transaction issue missing: \(report.issues)")
        XCTAssertEqual(report.blockingIssues.count, 2, "blocking: \(report.blockingIssues)")
        XCTAssertTrue(report.canQuarantineAndRetry, "quarantinable: \(report.quarantinableIssues)")
        XCTAssertEqual(report.trackCount, 0)
    }

    func testQuarantinePreservesBrokenRecordsUnderRecovery() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let validSource = try makeValidSource(in: fixture.paths)
        let brokenSourceID = UUID()
        let brokenSourceURL = fixture.paths.sourceRootURL(for: brokenSourceID)
        try FileManager.default.createDirectory(at: brokenSourceURL, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: brokenSourceURL.appendingPathComponent("note.txt"))
        let pendingURL = fixture.paths.pendingTransactionsRootURL.appendingPathComponent("broken.json")
        try Data("broken record".utf8).write(to: pendingURL)

        let report = await LibraryRepairInspector.inspect(rootURL: fixture.paths.rootURL)
        let result = LibraryRepairQuarantineService(rootURL: fixture.paths.rootURL).quarantine(
            report.issues.filter { $0.quarantineTarget != nil },
            libraryID: report.libraryID
        )

        XCTAssertEqual(result.moved.count, 2)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: brokenSourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.paths.sourceDescriptorURL(for: validSource.id).path
        ))
        let recoveredSources = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.recoverySourcesRootURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recoveredSources.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveredSources[0].appendingPathComponent("note.txt").path
        ))
        let recoveredTransactions = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.recoveryTransactionsRootURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recoveredTransactions.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: recoveredTransactions[0]),
            Data("broken record".utf8)
        )

        let after = await LibraryRepairInspector.inspect(rootURL: fixture.paths.rootURL)
        XCTAssertTrue(after.issues.isEmpty)
    }

    func testQuarantineSkipsRecordThatNowLoads() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let sourceID = UUID()
        let directory = fixture.paths.sourceRootURL(for: sourceID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptorURL = fixture.paths.sourceDescriptorURL(for: sourceID)
        try Data("not json".utf8).write(to: descriptorURL)
        let report = await LibraryRepairInspector.inspect(rootURL: fixture.paths.rootURL)
        let issue = try XCTUnwrap(report.issues.first { $0.kind == .source })

        // The source became readable after inspection. Quarantine must not
        // treat the stale report as proof that it is still broken.
        let descriptor = ReferencedSourceDescriptor(
            id: sourceID,
            rootBookmarkData: Data("bookmark".utf8),
            lastKnownPath: "/Music",
            displayName: "Music"
        )
        try await ReferencedSourceStore(paths: fixture.paths).save(descriptor)

        let result = LibraryRepairQuarantineService(rootURL: fixture.paths.rootURL).quarantine(
            [issue],
            libraryID: report.libraryID
        )
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.skipped, [directory])
        XCTAssertTrue(FileManager.default.fileExists(atPath: descriptorURL.path))
    }

    func testResidueCleanupDeletesOnlyVerifiedAudioOnlyFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LibraryPaths(rootURL: root)
        try paths.createRequiredDirectories()
        let trackID = UUID()
        let folder = paths.trackFolderURL(for: trackID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folder.appendingPathComponent("audio.mp3"))
        try ImportTrackFolderMarker(trackID: trackID, sessionID: UUID()).write(to: folder)

        let report = LibraryMaintenanceService().cleanupFailedImportTrackDirectories(
            tracksRootURL: paths.tracksRootURL,
            referencedTrackIDs: [],
            importActivity: LibraryImportActivitySnapshot(isImporting: false, activeTrackIDs: []),
            reason: "test"
        )

        XCTAssertEqual(report.deletedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: paths.tracksRootURL.path)
        XCTAssertTrue(siblings.isEmpty)
    }

    func testResidueCleanupKeepsUnmarkedAudioFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LibraryPaths(rootURL: root)
        try paths.createRequiredDirectories()
        let trackID = UUID()
        let folder = paths.trackFolderURL(for: trackID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("user content".utf8).write(to: folder.appendingPathComponent("audio.mp3"))

        let report = LibraryMaintenanceService().cleanupFailedImportTrackDirectories(
            tracksRootURL: paths.tracksRootURL,
            referencedTrackIDs: [],
            importActivity: LibraryImportActivitySnapshot(isImporting: false, activeTrackIDs: []),
            reason: "test"
        )

        XCTAssertEqual(report.deletedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testResidueCleanupKeepsFolderWhoseAudioIsNotARegularFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LibraryPaths(rootURL: root)
        try paths.createRequiredDirectories()
        let trackID = UUID()
        let folder = paths.trackFolderURL(for: trackID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("elsewhere.mp3")
        try Data("audio".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("audio.mp3"),
            withDestinationURL: target
        )
        try ImportTrackFolderMarker(trackID: trackID, sessionID: UUID()).write(to: folder)

        let report = LibraryMaintenanceService().cleanupFailedImportTrackDirectories(
            tracksRootURL: paths.tracksRootURL,
            referencedTrackIDs: [],
            importActivity: LibraryImportActivitySnapshot(isImporting: false, activeTrackIDs: []),
            reason: "test"
        )

        XCTAssertEqual(report.deletedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testStagingDiscardRequiresTheManifestCreatedByThisTransaction() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-discard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let operatorUnderTest = ProductionLibraryLifecycleFileOperator(
            sqliteExecutableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            sqliteCheckTimeout: 1
        )
        let manifest = MusicLibraryManifest(displayName: "New", mode: .managed)
        let staging = root.appendingPathComponent(".kmgccc-player-library-\(UUID().uuidString)")
        try await operatorUnderTest.createStagedLibrary(at: staging, manifest: manifest)

        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.discardOwnedStaging(
                at: staging,
                expectedLibraryID: UUID()
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))

        try await operatorUnderTest.discardOwnedStaging(
            at: staging,
            expectedLibraryID: manifest.libraryID
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    private struct RepairFixture {
        let root: URL
        let paths: LibraryPaths
        let manifest: MusicLibraryManifest
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixture() throws -> RepairFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-repair-\(UUID().uuidString)", isDirectory: true)
        let paths = LibraryPaths(rootURL: root)
        try paths.createRequiredDirectories()
        let manifest = MusicLibraryManifest(displayName: "Repair", mode: .referenced)
        try manifest.write(to: paths.manifestURL)
        try LibraryScopedSettingsFile.save(LibraryScopedSettings(), to: paths.librarySettingsURL)
        return RepairFixture(root: root, paths: paths, manifest: manifest)
    }

    @discardableResult
    private func makeValidSource(in paths: LibraryPaths) throws -> ReferencedSourceDescriptor {
        let source = ReferencedSourceDescriptor(
            rootBookmarkData: Data("bookmark".utf8),
            lastKnownPath: "/Music",
            displayName: "Music"
        )
        try FileManager.default.createDirectory(
            at: paths.sourceRootURL(for: source.id),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(source).write(to: paths.sourceDescriptorURL(for: source.id))
        return source
    }
}
