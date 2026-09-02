import Foundation

nonisolated enum LibraryRemovalNextAction: Sendable, Equatable {
    case activated(LibraryContext)
    case chooseLibrary
}

nonisolated enum LibraryRemovalReplayResult: Sendable, Equatable {
    case noPendingRepair
    case cancelled
    case removed(mode: MusicLibraryMode, didRemoveActive: Bool)
}

nonisolated enum LibraryRemovalError: Error, Equatable, LocalizedError {
    case libraryNotRegistered, manifestMismatch, closeFailed, recycleFailed
    case intentWriteFailed, pendingRepair, recoveryFailed
    case transactionInProgress, securityScopeDenied

    var errorDescription: String? {
        switch self {
        case .libraryNotRegistered:
            return "资料库不存在或已被移除。"
        case .manifestMismatch:
            return "资料库清单与登记记录不一致，无法安全删除。"
        case .closeFailed:
            return "资料库会话未能正常关闭，请稍后重试。"
        case .recycleFailed:
            return "移入废纸篓失败，文件可能被其他程序占用。"
        case .intentWriteFailed:
            return "无法写入删除恢复计划，已中止删除以保护数据。"
        case .pendingRepair:
            return "上一次删除尚未完成，请先重新连接该资料库再试。"
        case .recoveryFailed:
            return "删除恢复数据已损坏，无法继续操作。"
        case .transactionInProgress:
            return "有其他资料库操作正在进行，请稍后再试。"
        case .securityScopeDenied:
            return "没有访问资料库所在文件夹的权限。"
        }
    }
}

nonisolated enum LibraryDisplayNameUpdateError: Error, Equatable {
    case invalidDisplayName, libraryNotRegistered, manifestMismatch, manifestWriteFailed
    case registryWriteFailedRolledBack, registryWriteFailedRollbackFailed
    case transactionInProgress, securityScopeDenied
}

nonisolated struct LibraryRemovalRepairIntent: Codable, Sendable, Equatable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let libraryID: UUID
    let mode: MusicLibraryMode
    let rootPathBeforeRecycle: String
    let registryBefore: MusicLibraryRegistry

    init(libraryID: UUID, mode: MusicLibraryMode, rootPathBeforeRecycle: String, registryBefore: MusicLibraryRegistry) {
        self.schemaVersion = Self.schemaVersion
        self.libraryID = libraryID
        self.mode = mode
        self.rootPathBeforeRecycle = rootPathBeforeRecycle
        self.registryBefore = registryBefore
    }
}

nonisolated enum LibraryRemovalRepairIntentFile {
    static func load(from url: URL) throws -> LibraryRemovalRepairIntent? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let intent = try JSONDecoder().decode(LibraryRemovalRepairIntent.self, from: Data(contentsOf: url))
        guard intent.schemaVersion == LibraryRemovalRepairIntent.schemaVersion else { throw LibraryRemovalError.recoveryFailed }
        return intent
    }

    static func save(_ intent: LibraryRemovalRepairIntent, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(intent).write(to: url, options: .atomic)
    }

    static func remove(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

@MainActor
final class LibraryRemovalService {
    private let registryStore: MusicLibraryRegistryStore
    private let sessionController: LibrarySessionController
    private let bookmarkResolver: any BookmarkResolving
    private let recycler: any LibraryRecycling
    private let gate: LibraryLifecycleTransactionGate
    private let requiresSecurityScope: Bool
    private let intentURL: URL
    private var generation: UInt64

    init(
        registryStore: MusicLibraryRegistryStore,
        sessionController: LibrarySessionController,
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        recycler: any LibraryRecycling = MacOSLibraryRecycler(),
        gate: LibraryLifecycleTransactionGate = LibraryLifecycleTransactionGate(),
        requiresSecurityScope: Bool = false,
        intentURL: URL? = nil,
        initialGeneration: UInt64 = 200
    ) {
        self.registryStore = registryStore
        self.sessionController = sessionController
        self.bookmarkResolver = bookmarkResolver
        self.recycler = recycler
        self.gate = gate
        self.requiresSecurityScope = requiresSecurityScope
        self.intentURL = intentURL ?? registryStore.fileURL.deletingLastPathComponent()
            .appendingPathComponent("LibraryRemovalRepair.json")
        self.generation = initialGeneration
    }

    func replayPendingRepair() async throws -> LibraryRemovalReplayResult {
        do { try gate.acquire() }
        catch { throw LibraryRemovalError.transactionInProgress }
        defer { gate.release() }
        guard let intent = try LibraryRemovalRepairIntentFile.load(from: intentURL) else {
            return .noPendingRepair
        }
        if FileManager.default.fileExists(atPath: intent.rootPathBeforeRecycle) {
            let root = URL(fileURLWithPath: intent.rootPathBeforeRecycle, isDirectory: true)
            let manifest = try? MusicLibraryManifest.read(from: LibraryPaths(rootURL: root).manifestURL)
            if manifest?.libraryID == intent.libraryID, manifest?.mode == intent.mode {
                do { try LibraryRemovalRepairIntentFile.remove(at: intentURL) }
                catch { throw LibraryRemovalError.pendingRepair }
                return .cancelled
            }
        }
        let snapshot = await registryStore.snapshot()
        if snapshot.library(id: intent.libraryID) != nil {
            do { try await registryStore.remove(libraryID: intent.libraryID) }
            catch { throw LibraryRemovalError.pendingRepair }
        }
        do { try LibraryRemovalRepairIntentFile.remove(at: intentURL) }
        catch { throw LibraryRemovalError.pendingRepair }
        return .removed(
            mode: intent.mode,
            didRemoveActive: intent.registryBefore.activeLibraryID == intent.libraryID
        )
    }

    func moveToTrash(libraryID: UUID) async throws -> LibraryRemovalNextAction {
        do { try gate.acquire() }
        catch { throw LibraryRemovalError.transactionInProgress }
        defer { gate.release() }

        var intentPathIsDirectory: ObjCBool = false
        let intentPathExists = FileManager.default.fileExists(
            atPath: intentURL.path,
            isDirectory: &intentPathIsDirectory
        )
        if intentPathExists, !intentPathIsDirectory.boolValue {
            do {
                guard try LibraryRemovalRepairIntentFile.load(from: intentURL) == nil else {
                    throw LibraryRemovalError.pendingRepair
                }
            } catch let error as LibraryRemovalError { throw error }
            catch { throw LibraryRemovalError.pendingRepair }
        }
        let registry = await registryStore.snapshot()
        guard let descriptor = registry.library(id: libraryID) else { throw LibraryRemovalError.libraryNotRegistered }
        let lease: LibraryRootAccessLease
        do {
            lease = try LibraryRootAccessLease(descriptor: descriptor, resolver: bookmarkResolver, requiresSecurityScope: requiresSecurityScope)
        } catch { throw LibraryRemovalError.securityScopeDenied }
        let root = lease.rootURL
        let manifest: MusicLibraryManifest
        do { manifest = try MusicLibraryManifest.read(from: LibraryPaths(rootURL: root).manifestURL) }
        catch { throw LibraryRemovalError.manifestMismatch }
        guard manifest.libraryID == libraryID, manifest.mode == descriptor.modeProjection else {
            throw LibraryRemovalError.manifestMismatch
        }
        let previousSession = sessionController.activeLibraryContext
        let wasActive = previousSession?.id == libraryID
        if wasActive {
            do { try await sessionController.closeActiveSession() }
            catch { throw LibraryRemovalError.closeFailed }
        }

        do {
            try LibraryRemovalRepairIntentFile.save(
                .init(
                    libraryID: libraryID,
                    mode: manifest.mode,
                    rootPathBeforeRecycle: root.path,
                    registryBefore: registry
                ),
                to: intentURL
            )
        }
        catch {
            if wasActive {
                do { try await restoreLifecycleSession(previousSession, using: sessionController) }
                catch { throw LibraryRemovalError.recoveryFailed }
            }
            throw LibraryRemovalError.intentWriteFailed
        }
        do { try await recycler.recycle(root) }
        catch {
            try? LibraryRemovalRepairIntentFile.remove(at: intentURL)
            do { try await restoreLifecycleSession(previousSession, using: sessionController) }
            catch { throw LibraryRemovalError.recoveryFailed }
            throw LibraryRemovalError.recycleFailed
        }
        do { try await registryStore.remove(libraryID: libraryID) }
        catch { throw LibraryRemovalError.pendingRepair }
        do { try LibraryRemovalRepairIntentFile.remove(at: intentURL) }
        catch { throw LibraryRemovalError.pendingRepair }

        // Removing a non-active library must not unexpectedly move playback to
        // another library. Only the active-library removal needs successor
        // selection; the current session is already the correct destination.
        if !wasActive, let activeContext = sessionController.activeLibraryContext {
            return .activated(activeContext)
        }
        return await activateNextLibrary(afterRemovingMode: manifest.mode)
    }

    func updateDisplayName(libraryID: UUID, displayName: String, now: Date = Date()) async throws {
        do { try gate.acquire() }
        catch { throw LibraryDisplayNameUpdateError.transactionInProgress }
        defer { gate.release() }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryDisplayNameUpdateError.invalidDisplayName }
        let registry = await registryStore.snapshot()
        guard let descriptor = registry.library(id: libraryID) else { throw LibraryDisplayNameUpdateError.libraryNotRegistered }
        let lease: LibraryRootAccessLease
        do {
            lease = try LibraryRootAccessLease(descriptor: descriptor, resolver: bookmarkResolver, requiresSecurityScope: requiresSecurityScope)
        } catch { throw LibraryDisplayNameUpdateError.securityScopeDenied }
        let manifestURL = LibraryPaths(rootURL: lease.rootURL).manifestURL
        let original: MusicLibraryManifest
        do { original = try MusicLibraryManifest.read(from: manifestURL) }
        catch { throw LibraryDisplayNameUpdateError.manifestMismatch }
        guard original.libraryID == libraryID, original.mode == descriptor.modeProjection else {
            throw LibraryDisplayNameUpdateError.manifestMismatch
        }
        let bookmark: Data
        do {
            bookmark = lease.isStale
                ? try bookmarkResolver.refreshBookmark(for: lease.rootURL)
                : descriptor.rootBookmarkData
        } catch { throw LibraryDisplayNameUpdateError.registryWriteFailedRolledBack }
        var updated = original
        updated.displayName = name
        updated.updatedAt = now
        var registryAfter = registry
        guard let index = registryAfter.libraries.firstIndex(where: { $0.id == libraryID }) else {
            throw LibraryDisplayNameUpdateError.libraryNotRegistered
        }
        registryAfter.libraries[index].displayName = name
        registryAfter.libraries[index].rootBookmarkData = bookmark
        registryAfter.libraries[index].lastKnownPath = lease.rootURL.path
        do { try updated.write(to: manifestURL) }
        catch { throw LibraryDisplayNameUpdateError.manifestWriteFailed }
        do { try await registryStore.replaceSnapshot(registryAfter) }
        catch {
            do { try original.write(to: manifestURL) }
            catch { throw LibraryDisplayNameUpdateError.registryWriteFailedRollbackFailed }
            throw LibraryDisplayNameUpdateError.registryWriteFailedRolledBack
        }
    }

    private func activateNextLibrary(afterRemovingMode mode: MusicLibraryMode) async -> LibraryRemovalNextAction {
        let updated = await registryStore.snapshot()
        var candidateIDs: [UUID] = []
        if let preferredID = updated.recentLibraryID(for: mode) {
            candidateIDs.append(preferredID)
        }
        candidateIDs.append(contentsOf: updated.libraries
            .filter { $0.modeProjection == mode }
            .map(\.id))
        candidateIDs.append(contentsOf: updated.libraries.map(\.id))

        var seen = Set<UUID>()
        for candidateID in candidateIDs where seen.insert(candidateID).inserted {
            guard let candidate = updated.library(id: candidateID) else { continue }
            do {
                let lease = try LibraryRootAccessLease(
                    descriptor: candidate,
                    resolver: bookmarkResolver,
                    requiresSecurityScope: requiresSecurityScope
                )
                let manifest = try MusicLibraryManifest.read(from: LibraryPaths(rootURL: lease.rootURL).manifestURL)
                guard manifest.libraryID == candidate.id, manifest.mode == candidate.modeProjection else { continue }
                let bookmark = try bookmarkResolver.refreshBookmark(for: lease.rootURL)
                generation &+= 1
                let context = LibraryContext(
                    manifest: manifest,
                    rootURL: lease.rootURL,
                    rootBookmarkData: bookmark,
                    generation: generation
                )

                // Commit the successor pointer before opening the session. If
                // session construction fails, the registry still describes a
                // recoverable successor for the next startup pass.
                try await registryStore.updateBookmark(
                    libraryID: candidate.id,
                    bookmarkData: bookmark,
                    lastKnownPath: lease.rootURL.path,
                    modeProjection: manifest.mode
                )
                try await registryStore.setActiveLibrary(id: context.id, manifestMode: context.mode)
                do {
                    try await sessionController.switchToLibrary(context)
                } catch {
                    // Keep the post-removal registry honest if opening this
                    // particular candidate fails after the pointer commit.
                    try? await registryStore.replaceSnapshot(updated)
                    throw error
                }
                return .activated(context)
            } catch {
                continue
            }
        }
        return .chooseLibrary
    }
}
