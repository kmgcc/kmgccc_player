import AppKit
import Foundation

nonisolated protocol LibraryRecycling: Sendable {
    func recycle(_ url: URL) async throws
}

nonisolated struct MacOSLibraryRecycler: LibraryRecycling {
    func recycle(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([url]) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

nonisolated enum LibraryRelocationResult: Sendable, Equatable {
    case moved(LibraryContext, transfer: LibraryRelocationTransfer)
    case movedWithOldCopyRemaining(LibraryContext, transfer: LibraryRelocationTransfer)
}

nonisolated enum LibraryRelocationError: Error, Equatable {
    case libraryNotRegistered, destinationExists, closeFailed, copyFailed, validationFailed
    case publicationFailed, newSessionFailed, registryCommitFailed, recoveryFailed, recoveryConflict
    case transactionInProgress, securityScopeDenied, pendingRepair, pendingMutations
}

nonisolated enum LibraryRelocationRepairPhase: String, Codable, Sendable {
    case prepared, sourceMoved, published, registryCommitted
}

nonisolated struct LibraryRelocationRepairIntent: Codable, Sendable, Equatable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let libraryID: UUID
    let mode: MusicLibraryMode
    let sourcePath: String
    let stagingPath: String
    let destinationPath: String
    let authority: LibraryRelocationAuthoritySnapshot
    let registryBefore: MusicLibraryRegistry
    var phase: LibraryRelocationRepairPhase
    var transfer: LibraryRelocationTransfer?
    var destinationBookmark: Data?

    init(
        libraryID: UUID,
        mode: MusicLibraryMode,
        source: URL,
        staging: URL,
        destination: URL,
        authority: LibraryRelocationAuthoritySnapshot,
        registryBefore: MusicLibraryRegistry
    ) {
        schemaVersion = Self.schemaVersion
        self.libraryID = libraryID
        self.mode = mode
        sourcePath = source.standardizedFileURL.path
        stagingPath = staging.standardizedFileURL.path
        destinationPath = destination.standardizedFileURL.path
        self.authority = authority
        self.registryBefore = registryBefore
        phase = .prepared
    }
}

nonisolated enum LibraryRelocationRepairIntentFile {
    static func load(from url: URL) throws -> LibraryRelocationRepairIntent? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(LibraryRelocationRepairIntent.self, from: Data(contentsOf: url))
        guard value.schemaVersion == LibraryRelocationRepairIntent.schemaVersion else {
            throw LibraryRelocationError.recoveryConflict
        }
        return value
    }

    static func save(_ value: LibraryRelocationRepairIntent, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func remove(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

@MainActor
final class LibraryRelocationService {
    private(set) var preservedRecoveryCopies: [URL] = []
    private let registryStore: MusicLibraryRegistryStore
    private let sessionController: LibrarySessionController
    private let sessionValidator: any LibrarySessionValidating
    private let bookmarkResolver: any BookmarkResolving
    private let fileOperator: any LibraryLifecycleFileOperating
    private let recycler: any LibraryRecycling
    private let gate: LibraryLifecycleTransactionGate
    private let requiresSecurityScope: Bool
    private let intentURL: URL
    private var generation: UInt64

    init(
        registryStore: MusicLibraryRegistryStore,
        sessionController: LibrarySessionController,
        sessionValidator: any LibrarySessionValidating,
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        fileOperator: any LibraryLifecycleFileOperating = ProductionLibraryLifecycleFileOperator(),
        recycler: any LibraryRecycling = MacOSLibraryRecycler(),
        gate: LibraryLifecycleTransactionGate = LibraryLifecycleTransactionGate(),
        requiresSecurityScope: Bool = false,
        intentURL: URL? = nil,
        initialGeneration: UInt64 = 100
    ) {
        self.registryStore = registryStore
        self.sessionController = sessionController
        self.sessionValidator = sessionValidator
        self.bookmarkResolver = bookmarkResolver
        self.fileOperator = fileOperator
        self.recycler = recycler
        self.gate = gate
        self.requiresSecurityScope = requiresSecurityScope
        self.intentURL = intentURL ?? registryStore.fileURL.deletingLastPathComponent()
            .appendingPathComponent("LibraryRelocationRepair.json")
        generation = initialGeneration
    }

    func replayPendingRepair() async throws -> Bool {
        do { try gate.acquire() }
        catch { throw LibraryRelocationError.transactionInProgress }
        defer { gate.release() }
        preservedRecoveryCopies = []
        guard let intent = try LibraryRelocationRepairIntentFile.load(from: intentURL) else { return false }
        try await replay(intent)
        return true
    }

    func relocate(libraryID: UUID, toParent parentURL: URL) async throws -> LibraryRelocationResult {
        do { try gate.acquire() }
        catch { throw LibraryRelocationError.transactionInProgress }
        defer { gate.release() }
        do {
            guard try LibraryRelocationRepairIntentFile.load(from: intentURL) == nil else {
                throw LibraryRelocationError.pendingRepair
            }
        } catch let error as LibraryRelocationError { throw error }
        catch { throw LibraryRelocationError.pendingRepair }

        let beforeRegistry = try await registryStore.reload()
        guard let descriptor = beforeRegistry.library(id: libraryID) else {
            throw LibraryRelocationError.libraryNotRegistered
        }
        let lease: LibraryRootAccessLease
        do {
            lease = try LibraryRootAccessLease(
                descriptor: descriptor,
                resolver: bookmarkResolver,
                requiresSecurityScope: requiresSecurityScope
            )
        } catch { throw LibraryRelocationError.securityScopeDenied }
        let sourceURL = lease.rootURL
        let manifest: MusicLibraryManifest
        do { manifest = try MusicLibraryManifest.read(from: LibraryPaths(rootURL: sourceURL).manifestURL) }
        catch { throw LibraryRelocationError.validationFailed }
        guard manifest.libraryID == descriptor.id, manifest.mode == descriptor.modeProjection else {
            throw LibraryRelocationError.validationFailed
        }
        // Moving the root while a durable commit record is unresolved would
        // carry an unknown projection between volumes and make later
        // verification depend on the new location. Refuse until the record is
        // adjudicated.
        guard !LibraryMutationJournal.hasPendingRecords(paths: LibraryPaths(rootURL: sourceURL)) else {
            throw LibraryRelocationError.pendingMutations
        }

        let destination = parentURL.appendingPathComponent(LibraryPaths.rootDirectoryName, isDirectory: true).standardizedFileURL
        if destination == sourceURL {
            generation &+= 1
            return .moved(makeContext(manifest, sourceURL, descriptor.rootBookmarkData), transfer: .sameVolume)
        }
        guard !(await fileOperator.itemExists(at: destination)) else { throw LibraryRelocationError.destinationExists }
        let staging = parentURL.appendingPathComponent(".kmgccc-player-relocation-\(UUID().uuidString)", isDirectory: true)
        let previousSession = sessionController.activeLibraryContext
        let wasActive = previousSession?.id == libraryID
        if wasActive {
            do { try await sessionController.closeActiveSession() }
            catch { throw LibraryRelocationError.closeFailed }
        }
        let writerLease: LibraryWriterLease
        do { writerLease = try LibraryWriterLease.acquire(paths: LibraryPaths(rootURL: sourceURL)) }
        catch {
            if wasActive {
                do { try await restoreLifecycleSession(previousSession, using: sessionController) }
                catch { throw LibraryRelocationError.recoveryFailed }
            }
            throw error
        }
        defer { writerLease.release() }
        let authority: LibraryRelocationAuthoritySnapshot
        do {
            let lockedManifest = try MusicLibraryManifest.read(from: LibraryPaths(rootURL: sourceURL).manifestURL)
            guard lockedManifest.libraryID == manifest.libraryID, lockedManifest.mode == manifest.mode else {
                throw LibraryRelocationError.validationFailed
            }
            authority = try await fileOperator.captureRelocationAuthority(at: sourceURL)
        }
        catch {
            writerLease.release()
            do {
                if wasActive {
                    try await Task { @MainActor in
                        try await restoreLifecycleSession(previousSession, using: sessionController)
                    }.value
                }
            }
            catch { throw LibraryRelocationError.recoveryFailed }
            if error is CancellationError { throw CancellationError() }
            throw LibraryRelocationError.validationFailed
        }
        var intent = LibraryRelocationRepairIntent(
            libraryID: libraryID,
            mode: manifest.mode,
            source: sourceURL,
            staging: staging,
            destination: destination,
            authority: authority,
            registryBefore: beforeRegistry
        )
        do { try LibraryRelocationRepairIntentFile.save(intent, to: intentURL) }
        catch {
            writerLease.release()
            do { if wasActive { try await restoreLifecycleSession(previousSession, using: sessionController) } }
            catch { throw LibraryRelocationError.recoveryFailed }
            throw LibraryRelocationError.recoveryFailed
        }

        var transferredURL: URL?
        var attemptedRegistryCommit = false
        var committedDescriptor: MusicLibraryBookmark?
        do {
            let transfer = try await fileOperator.relocate(from: sourceURL, toStaging: staging)
            transferredURL = staging
            intent.transfer = transfer
            intent.phase = .sourceMoved
            try LibraryRelocationRepairIntentFile.save(intent, to: intentURL)
            try await fileOperator.validateRelocation(
                at: staging,
                expectedAuthority: authority,
                expectedID: libraryID,
                expectedMode: manifest.mode
            )
            try await fileOperator.publishStaging(at: staging, to: destination)
            transferredURL = destination
            intent.phase = .published
            try LibraryRelocationRepairIntentFile.save(intent, to: intentURL)

            let bookmark = try bookmarkResolver.refreshBookmark(for: destination)
            intent.destinationBookmark = bookmark
            try LibraryRelocationRepairIntentFile.save(intent, to: intentURL)
            generation &+= 1
            let newContext = makeContext(manifest, destination, bookmark)
            // A same-volume move carries the lock file to the destination.
            // Release it before the destination session acquires its lease.
            if transfer == .sameVolume { writerLease.release() }
            if wasActive {
                try await sessionController.switchToLibrary(newContext)
            } else {
                try await sessionValidator.validate(newContext)
            }

            let committed = try committedRegistry(for: intent, bookmark: bookmark)
            guard let destinationDescriptor = committed.library(id: libraryID) else {
                throw LibraryRelocationError.recoveryConflict
            }
            attemptedRegistryCommit = true
            try await registryStore.replaceDescriptor(expected: descriptor, with: destinationDescriptor)
            committedDescriptor = destinationDescriptor
            intent.phase = .registryCommitted
            try LibraryRelocationRepairIntentFile.save(intent, to: intentURL)

            if transfer == .copiedAcrossVolumes {
                // The source path can be replaced independently of the open
                // lock file. Keep the old copy until the user can inspect it.
                try LibraryRelocationRepairIntentFile.remove(at: intentURL)
                return .movedWithOldCopyRemaining(newContext, transfer: transfer)
            }
            try LibraryRelocationRepairIntentFile.remove(at: intentURL)
            return .moved(newContext, transfer: transfer)
        } catch {
            do {
                if wasActive, sessionController.activeLibraryContext?.rootURL == destination {
                    try await sessionController.closeActiveSession()
                }
                if let committedDescriptor {
                    // Claim the registry row before moving the directory. If
                    // another writer changed it, leave the destination intact
                    // and retain the intent for explicit recovery.
                    try await registryStore.replaceDescriptor(expected: committedDescriptor, with: descriptor)
                }
                if let transferredURL, let transfer = intent.transfer {
                    let rollbackLease: LibraryWriterLease?
                    if writerLease.isReleased || transfer == .copiedAcrossVolumes {
                        rollbackLease = try LibraryWriterLease.acquire(paths: LibraryPaths(rootURL: transferredURL))
                    } else {
                        rollbackLease = nil
                    }
                    defer { rollbackLease?.release() }
                    try await fileOperator.rollbackRelocation(from: transferredURL, to: sourceURL, transfer: transfer)
                }
                writerLease.release()
                try await restoreLifecycleSession(previousSession, using: sessionController)
                try LibraryRelocationRepairIntentFile.remove(at: intentURL)
            } catch {
                throw LibraryRelocationError.recoveryFailed
            }
            if error is LibraryRelocationError { throw error }
            if intent.phase == .prepared { throw LibraryRelocationError.copyFailed }
            if attemptedRegistryCommit { throw LibraryRelocationError.registryCommitFailed }
            throw LibraryRelocationError.newSessionFailed
        }
    }

    private func replay(_ intent: LibraryRelocationRepairIntent) async throws {
        guard let beforeDescriptor = intent.registryBefore.library(id: intent.libraryID),
              beforeDescriptor.modeProjection == intent.mode else {
            throw LibraryRelocationError.recoveryConflict
        }
        let source = URL(fileURLWithPath: intent.sourcePath, isDirectory: true)
        let staging = URL(fileURLWithPath: intent.stagingPath, isDirectory: true)
        let destination = URL(fileURLWithPath: intent.destinationPath, isDirectory: true)
        // A second App process can update the shared registry after this
        // actor was initialized. Recovery must inspect the durable state.
        let current = try await registryStore.reload()
        let committed = try intent.destinationBookmark.map { try committedRegistry(for: intent, bookmark: $0) }
        // Other libraries and the active selection can legitimately change
        // while a relocation is awaiting replay. Only the moved row belongs
        // to this transaction; retain all unrelated registry updates.
        let currentDescriptor = current.library(id: intent.libraryID)
        let registryIsBefore = currentDescriptor == beforeDescriptor
        let registryIsCommitted = currentDescriptor != nil
            && currentDescriptor == committed?.library(id: intent.libraryID)
        guard registryIsBefore || registryIsCommitted else { throw LibraryRelocationError.recoveryConflict }

        if registryIsCommitted {
            guard let descriptor = current.library(id: intent.libraryID),
                  descriptor.lastKnownPath == destination.standardizedFileURL.path,
                  await hasLibraryIdentity(destination, intent: intent) else {
                throw LibraryRelocationError.recoveryConflict
            }
            // The original path may have been reused or edited since the
            // interrupted move. Preserve it for the user to inspect.
            if await fileOperator.itemExists(at: staging) {
                preservedRecoveryCopies.append(staging)
            }
            if intent.transfer == .copiedAcrossVolumes,
               await fileOperator.itemExists(at: source) { preservedRecoveryCopies.append(source) }
            try LibraryRelocationRepairIntentFile.remove(at: intentURL)
            return
        }

        if await fileOperator.itemExists(at: source) {
            let replayLease = try LibraryWriterLease.acquire(paths: LibraryPaths(rootURL: source))
            defer { replayLease.release() }
            guard await hasLibraryIdentity(source, intent: intent) else { throw LibraryRelocationError.recoveryConflict }
            for orphan in [staging, destination] where await fileOperator.itemExists(at: orphan) {
                preservedRecoveryCopies.append(orphan)
            }
        } else if await fileOperator.itemExists(at: staging) {
            guard intent.transfer != .copiedAcrossVolumes, await matchesLibrary(staging, intent: intent) else {
                throw LibraryRelocationError.recoveryConflict
            }
            let replayLease = try LibraryWriterLease.acquire(paths: LibraryPaths(rootURL: staging))
            defer { replayLease.release() }
            guard await matchesLibrary(staging, intent: intent) else { throw LibraryRelocationError.recoveryConflict }
            guard try await registryStore.reload().library(id: intent.libraryID) == beforeDescriptor else {
                throw LibraryRelocationError.recoveryConflict
            }
            try await fileOperator.rollbackRelocation(from: staging, to: source, transfer: .sameVolume)
        } else if await fileOperator.itemExists(at: destination) {
            guard intent.transfer != .copiedAcrossVolumes, await matchesLibrary(destination, intent: intent) else {
                throw LibraryRelocationError.recoveryConflict
            }
            let replayLease = try LibraryWriterLease.acquire(paths: LibraryPaths(rootURL: destination))
            defer { replayLease.release() }
            guard await matchesLibrary(destination, intent: intent) else { throw LibraryRelocationError.recoveryConflict }
            guard try await registryStore.reload().library(id: intent.libraryID) == beforeDescriptor else {
                throw LibraryRelocationError.recoveryConflict
            }
            try await fileOperator.rollbackRelocation(from: destination, to: source, transfer: .sameVolume)
        } else {
            throw LibraryRelocationError.recoveryConflict
        }
        try LibraryRelocationRepairIntentFile.remove(at: intentURL)
    }

    private func matchesLibrary(_ url: URL, intent: LibraryRelocationRepairIntent) async -> Bool {
        do {
            try await fileOperator.validateRelocation(
                at: url,
                expectedAuthority: intent.authority,
                expectedID: intent.libraryID,
                expectedMode: intent.mode
            )
            return true
        } catch { return false }
    }

    private func hasLibraryIdentity(_ url: URL, intent: LibraryRelocationRepairIntent) async -> Bool {
        do {
            try await fileOperator.validateLibrary(at: url, expectedID: intent.libraryID, expectedMode: intent.mode)
            return true
        } catch { return false }
    }

    private func committedRegistry(for intent: LibraryRelocationRepairIntent, bookmark: Data) throws -> MusicLibraryRegistry {
        var registry = intent.registryBefore
        guard let index = registry.libraries.firstIndex(where: { $0.id == intent.libraryID }) else {
            throw LibraryRelocationError.recoveryConflict
        }
        registry.libraries[index].rootBookmarkData = bookmark
        registry.libraries[index].lastKnownPath = intent.destinationPath
        registry.libraries[index].modeProjection = intent.mode
        return try registry.validated()
    }

    private func makeContext(_ manifest: MusicLibraryManifest, _ rootURL: URL, _ bookmark: Data) -> LibraryContext {
        LibraryContext(manifest: manifest, rootURL: rootURL, rootBookmarkData: bookmark, generation: generation)
    }
}
