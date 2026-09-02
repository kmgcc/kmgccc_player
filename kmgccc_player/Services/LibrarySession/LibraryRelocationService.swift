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
    case transactionInProgress, securityScopeDenied, pendingRepair
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

        let beforeRegistry = await registryStore.snapshot()
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

        let destination = parentURL.appendingPathComponent(LibraryPaths.rootDirectoryName, isDirectory: true).standardizedFileURL
        if destination == sourceURL {
            generation &+= 1
            return .moved(makeContext(manifest, sourceURL, descriptor.rootBookmarkData), transfer: .sameVolume)
        }
        guard !(await fileOperator.itemExists(at: destination)) else { throw LibraryRelocationError.destinationExists }
        let staging = parentURL.appendingPathComponent(".kmgccc-player-relocation-\(UUID().uuidString)", isDirectory: true)
        let authority: LibraryRelocationAuthoritySnapshot
        do { authority = try await fileOperator.captureRelocationAuthority(at: sourceURL) }
        catch { throw LibraryRelocationError.validationFailed }
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
        catch { throw LibraryRelocationError.recoveryFailed }

        let previousSession = sessionController.activeLibraryContext
        let wasActive = previousSession?.id == libraryID
        if wasActive {
            do { try await sessionController.closeActiveSession() }
            catch {
                try? LibraryRelocationRepairIntentFile.remove(at: intentURL)
                throw LibraryRelocationError.closeFailed
            }
        }

        var transferredURL: URL?
        var attemptedRegistryCommit = false
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
            if wasActive {
                try await sessionController.switchToLibrary(newContext)
            } else {
                try await sessionValidator.validate(newContext)
            }

            let committed = try committedRegistry(for: intent, bookmark: bookmark)
            attemptedRegistryCommit = true
            try await registryStore.replaceSnapshot(committed)
            intent.phase = .registryCommitted
            try LibraryRelocationRepairIntentFile.save(intent, to: intentURL)

            if transfer == .copiedAcrossVolumes {
                do {
                    try await recycler.recycle(sourceURL)
                    try LibraryRelocationRepairIntentFile.remove(at: intentURL)
                    return .moved(newContext, transfer: transfer)
                } catch {
                    return .movedWithOldCopyRemaining(newContext, transfer: transfer)
                }
            }
            try LibraryRelocationRepairIntentFile.remove(at: intentURL)
            return .moved(newContext, transfer: transfer)
        } catch {
            do {
                if let transferredURL, let transfer = intent.transfer {
                    try await fileOperator.rollbackRelocation(from: transferredURL, to: sourceURL, transfer: transfer)
                }
                try await restoreLifecycleSession(previousSession, using: sessionController)
                try await registryStore.replaceSnapshot(beforeRegistry)
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
        let current = await registryStore.snapshot()
        let committed = try intent.destinationBookmark.map { try committedRegistry(for: intent, bookmark: $0) }
        let registryIsBefore = current == intent.registryBefore
        let registryIsCommitted = committed == current
        guard registryIsBefore || registryIsCommitted else { throw LibraryRelocationError.recoveryConflict }

        if registryIsCommitted {
            guard let descriptor = current.library(id: intent.libraryID),
                  descriptor.lastKnownPath == destination.standardizedFileURL.path,
                  await matchesLibrary(destination, intent: intent) else {
                throw LibraryRelocationError.recoveryConflict
            }
            if await fileOperator.itemExists(at: source), intent.transfer == .copiedAcrossVolumes {
                do { try await recycler.recycle(source) }
                catch { throw LibraryRelocationError.recoveryFailed }
            }
            if await fileOperator.itemExists(at: staging) {
                guard await matchesLibrary(staging, intent: intent) else { throw LibraryRelocationError.recoveryConflict }
                await fileOperator.removeItemIfPresent(at: staging)
            }
            try LibraryRelocationRepairIntentFile.remove(at: intentURL)
            return
        }

        if await fileOperator.itemExists(at: source) {
            guard await matchesLibrary(source, intent: intent) else { throw LibraryRelocationError.recoveryConflict }
            for orphan in [staging, destination] where await fileOperator.itemExists(at: orphan) {
                guard await matchesLibrary(orphan, intent: intent) else { throw LibraryRelocationError.recoveryConflict }
                await fileOperator.removeItemIfPresent(at: orphan)
            }
        } else if await fileOperator.itemExists(at: staging) {
            guard intent.transfer != .copiedAcrossVolumes, await matchesLibrary(staging, intent: intent) else {
                throw LibraryRelocationError.recoveryConflict
            }
            try await fileOperator.rollbackRelocation(from: staging, to: source, transfer: .sameVolume)
        } else if await fileOperator.itemExists(at: destination) {
            guard intent.transfer != .copiedAcrossVolumes, await matchesLibrary(destination, intent: intent) else {
                throw LibraryRelocationError.recoveryConflict
            }
            try await fileOperator.rollbackRelocation(from: destination, to: source, transfer: .sameVolume)
        } else {
            throw LibraryRelocationError.recoveryConflict
        }
        try await registryStore.replaceSnapshot(intent.registryBefore)
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
