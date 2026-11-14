//
//  MusicLibraryRegistryStore.swift
//  kmgccc_player
//
//  The only process-global index of known music libraries.
//

import Foundation
import Darwin

nonisolated struct MusicLibraryBookmark: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var displayName: String
    var rootBookmarkData: Data
    var lastKnownPath: String
    var modeProjection: MusicLibraryMode
}

nonisolated struct MusicLibraryRegistry: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var libraries: [MusicLibraryBookmark]
    var activeLibraryID: UUID?
    var recentManagedLibraryID: UUID?
    var recentReferencedLibraryID: UUID?
    var pendingFactoryDefaultReplacement: Bool?

    init(
        schemaVersion: Int = MusicLibraryRegistry.schemaVersion,
        libraries: [MusicLibraryBookmark] = [],
        activeLibraryID: UUID? = nil,
        recentManagedLibraryID: UUID? = nil,
        recentReferencedLibraryID: UUID? = nil,
        pendingFactoryDefaultReplacement: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.libraries = libraries
        self.activeLibraryID = activeLibraryID
        self.recentManagedLibraryID = recentManagedLibraryID
        self.recentReferencedLibraryID = recentReferencedLibraryID
        self.pendingFactoryDefaultReplacement = pendingFactoryDefaultReplacement
    }

    func validated() throws -> MusicLibraryRegistry {
        guard schemaVersion == Self.schemaVersion else {
            throw MusicLibraryRegistryError.unsupportedSchema(schemaVersion)
        }

        let ids = libraries.map(\.id)
        guard Set(ids).count == ids.count else {
            throw MusicLibraryRegistryError.duplicateLibraryID
        }

        let normalizedPaths = libraries.map {
            URL(fileURLWithPath: $0.lastKnownPath).standardizedFileURL.path
        }
        guard Set(normalizedPaths).count == normalizedPaths.count else {
            throw MusicLibraryRegistryError.duplicateLibraryPath
        }

        let knownIDs = Set(ids)
        for pointer in [activeLibraryID, recentManagedLibraryID, recentReferencedLibraryID].compactMap({ $0 }) {
            guard knownIDs.contains(pointer) else {
                throw MusicLibraryRegistryError.danglingLibraryReference(pointer)
            }
        }
        return self
    }

    func library(id: UUID) -> MusicLibraryBookmark? {
        libraries.first { $0.id == id }
    }

    func recentLibraryID(for mode: MusicLibraryMode) -> UUID? {
        switch mode {
        case .managed:
            return recentManagedLibraryID
        case .referenced:
            return recentReferencedLibraryID
        }
    }
}

nonisolated enum MusicLibraryRegistryError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case duplicateLibraryID
    case duplicateLibraryPath
    case danglingLibraryReference(UUID)
    case libraryNotFound(UUID)
    case libraryPathBelongsToAnotherID
    case corruptedRegistry(String)
    case externalModification
    case registryLocked
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported library registry schema: \(version)"
        case .duplicateLibraryID:
            return "The library registry contains a duplicate identifier."
        case .duplicateLibraryPath:
            return "The library registry contains a duplicate path."
        case .danglingLibraryReference(let id):
            return "The library registry contains an invalid reference: \(id.uuidString)"
        case .libraryNotFound(let id):
            return "The library is not registered: \(id.uuidString)"
        case .libraryPathBelongsToAnotherID:
            return "The selected path belongs to another registered library."
        case .corruptedRegistry:
            return "The library registry cannot be decoded."
        case .externalModification:
            return "资料库列表已被其他进程更新，请重试。"
        case .registryLocked:
            return "资料库列表正在由其他进程更新，请稍后重试。"
        case .unavailable(let reason):
            return "资料库列表无法读取：\(reason)"
        }
    }
}

nonisolated enum MusicLibraryRegistryFile {
    static func defaultURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "kmgccc.player"
    ) -> URL {
        #if DEBUG
        if let root = DebugLibraryIsolation.rootURL { return root.appendingPathComponent("LibraryRegistry.json") }
        #endif
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("LibraryRegistry.json")
    }

    static func load(from url: URL) throws -> MusicLibraryRegistry {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                return MusicLibraryRegistry()
            }
            throw error
        }
        do {
            let decoder = JSONDecoder()
            let registry = try decoder.decode(MusicLibraryRegistry.self, from: data)
            return try registry.validated()
        } catch let error as MusicLibraryRegistryError {
            throw error
        } catch {
            throw MusicLibraryRegistryError.corruptedRegistry(String(describing: error))
        }
    }

    static func save(_ registry: MusicLibraryRegistry, to url: URL) throws {
        _ = try registry.validated()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: url, options: .atomic)
    }
}

actor MusicLibraryRegistryStore {
    nonisolated static var defaultRegistryURL: URL {
        MusicLibraryRegistryFile.defaultURL()
    }

    nonisolated let fileURL: URL
    private(set) var startupFailure: String?
    private var registry: MusicLibraryRegistry
    private let beforeCommit: @Sendable () throws -> Void

    /// Preserve the original index on any read failure. The recovery store
    /// refuses writes until the underlying problem is resolved.
    nonisolated static func makeApplicationStore(
        fileURL: URL = MusicLibraryRegistryStore.defaultRegistryURL
    ) -> MusicLibraryRegistryStore {
        do {
            return try MusicLibraryRegistryStore(fileURL: fileURL)
        } catch {
            Log.error("[LibraryRegistry] persistent registry unavailable at \(fileURL.path): \(error)", category: .library)
            return MusicLibraryRegistryStore(recoveryFileURL: fileURL, reason: error.localizedDescription)
        }
    }

    init(
        fileURL: URL = MusicLibraryRegistryStore.defaultRegistryURL,
        beforeCommit: @escaping @Sendable () throws -> Void = {}
    ) throws {
        self.fileURL = fileURL
        self.startupFailure = nil
        self.registry = try MusicLibraryRegistryFile.load(from: fileURL)
        self.beforeCommit = beforeCommit
    }

    private init(recoveryFileURL: URL, reason: String) {
        self.fileURL = recoveryFileURL
        self.startupFailure = reason
        self.registry = MusicLibraryRegistry()
        self.beforeCommit = {}
    }

    func snapshot() -> MusicLibraryRegistry {
        registry
    }

    func reload() throws -> MusicLibraryRegistry {
        if let startupFailure, !FileManager.default.fileExists(atPath: fileURL.path) {
            throw MusicLibraryRegistryError.unavailable(startupFailure)
        }
        let loaded = try MusicLibraryRegistryFile.load(from: fileURL)
        registry = loaded
        startupFailure = nil
        return loaded
    }

    /// Test-only convenience used to simulate a registry written by another
    /// process. Production lifecycle code changes rows through the scoped
    /// operations below so unrelated concurrent updates survive.
    func replaceSnapshot(_ snapshot: MusicLibraryRegistry) throws {
        try commit { updated in updated = snapshot }
    }

    /// Replace one transaction-owned row without overwriting changes to
    /// unrelated libraries or pointers made while the caller was suspended.
    func replaceDescriptor(expected: MusicLibraryBookmark, with replacement: MusicLibraryBookmark) throws {
        guard expected.id == replacement.id else {
            throw MusicLibraryRegistryError.externalModification
        }
        try commit { updated in
            guard let index = updated.libraries.firstIndex(where: { $0.id == expected.id }),
                  updated.libraries[index] == expected else {
                throw MusicLibraryRegistryError.externalModification
            }
            updated.libraries[index] = replacement
        }
    }

    /// Undo only rows and pointers owned by a failed activation. Other
    /// libraries may have changed while session construction was suspended.
    func rollbackActivation(
        before: MusicLibraryRegistry,
        target: MusicLibraryBookmark,
        staleID: UUID?
    ) throws {
        try commit { updated in
            if let current = updated.library(id: target.id) {
                guard current == target || current == before.library(id: target.id) else {
                    throw MusicLibraryRegistryError.externalModification
                }
                if current == target {
                    guard let index = updated.libraries.firstIndex(where: { $0.id == target.id }) else {
                        throw MusicLibraryRegistryError.externalModification
                    }
                    if let original = before.library(id: target.id) {
                        updated.libraries[index] = original
                    } else {
                        updated.libraries.remove(at: index)
                    }
                }
            }
            if let staleID, let original = before.library(id: staleID), updated.library(id: staleID) == nil {
                let priorIndex = before.libraries.firstIndex { $0.id == staleID } ?? updated.libraries.count
                updated.libraries.insert(original, at: min(priorIndex, updated.libraries.count))
            }
            let knownIDs = Set(updated.libraries.map(\.id))
            func restoredPointer(_ current: UUID?, _ previous: UUID?) -> UUID? {
                if current == nil, previous == staleID, let previous, knownIDs.contains(previous) { return previous }
                guard let current, !knownIDs.contains(current) else { return current }
                return previous.flatMap { knownIDs.contains($0) ? $0 : nil }
            }
            updated.activeLibraryID = restoredPointer(updated.activeLibraryID, before.activeLibraryID)
            updated.recentManagedLibraryID = restoredPointer(updated.recentManagedLibraryID, before.recentManagedLibraryID)
            updated.recentReferencedLibraryID = restoredPointer(updated.recentReferencedLibraryID, before.recentReferencedLibraryID)
        }
    }

    func rollbackSelection(ifActive targetID: UUID, previous: MusicLibraryRegistry) throws {
        try commit { updated in
            guard updated.activeLibraryID == targetID else { return }
            let knownIDs = Set(updated.libraries.map(\.id))
            func existing(_ id: UUID?) -> UUID? { id.flatMap { knownIDs.contains($0) ? $0 : nil } }
            updated.activeLibraryID = existing(previous.activeLibraryID)
            if updated.recentManagedLibraryID == targetID {
                updated.recentManagedLibraryID = existing(previous.recentManagedLibraryID)
            }
            if updated.recentReferencedLibraryID == targetID {
                updated.recentReferencedLibraryID = existing(previous.recentReferencedLibraryID)
            }
        }
    }

    func register(_ descriptor: MusicLibraryBookmark) throws {
        try commit { updated in
            if let existingPath = updated.libraries.first(where: {
                URL(fileURLWithPath: $0.lastKnownPath).standardizedFileURL
                    == URL(fileURLWithPath: descriptor.lastKnownPath).standardizedFileURL
            }), existingPath.id != descriptor.id {
                throw MusicLibraryRegistryError.libraryPathBelongsToAnotherID
            }

            if let index = updated.libraries.firstIndex(where: { $0.id == descriptor.id }) {
                updated.libraries[index] = descriptor
            } else {
                updated.libraries.append(descriptor)
            }
        }
    }

    func updateDisplayName(libraryID: UUID, displayName: String) throws {
        try commit { updated in
            guard let index = updated.libraries.firstIndex(where: { $0.id == libraryID }) else {
                throw MusicLibraryRegistryError.libraryNotFound(libraryID)
            }
            updated.libraries[index].displayName = displayName
        }
    }

    func updateBookmark(
        libraryID: UUID,
        bookmarkData: Data,
        lastKnownPath: String,
        modeProjection: MusicLibraryMode
    ) throws {
        try commit { updated in
            guard let index = updated.libraries.firstIndex(where: { $0.id == libraryID }) else {
                throw MusicLibraryRegistryError.libraryNotFound(libraryID)
            }
            updated.libraries[index].rootBookmarkData = bookmarkData
            updated.libraries[index].lastKnownPath = lastKnownPath
            updated.libraries[index].modeProjection = modeProjection
        }
    }

    func setActiveLibrary(id: UUID, manifestMode: MusicLibraryMode) throws {
        try commit { updated in
            guard updated.library(id: id) != nil else {
                throw MusicLibraryRegistryError.libraryNotFound(id)
            }
            updated.activeLibraryID = id
            // A successfully activated library satisfies startup. An older
            // default replacement request must not override this selection.
            updated.pendingFactoryDefaultReplacement = nil
            switch manifestMode {
            case .managed:
                updated.recentManagedLibraryID = id
            case .referenced:
                updated.recentReferencedLibraryID = id
            }
        }
    }

    func remove(
        libraryID: UUID,
        requireFactoryDefaultReplacement: Bool = false,
        idempotent: Bool = false
    ) throws {
        if idempotent, registry.library(id: libraryID) == nil {
            // Replay after another process already removed the row; the
            // durable outcome already matches this transaction.
            let loaded = try MusicLibraryRegistryFile.load(from: fileURL)
            if loaded.library(id: libraryID) == nil {
                registry = loaded
                return
            }
        }
        try commit { updated in
            guard updated.libraries.contains(where: { $0.id == libraryID }) else {
                if idempotent { return }
                throw MusicLibraryRegistryError.libraryNotFound(libraryID)
            }
            updated.libraries.removeAll { $0.id == libraryID }
            if requireFactoryDefaultReplacement {
                updated.pendingFactoryDefaultReplacement = true
            }

            if updated.activeLibraryID == libraryID {
                updated.activeLibraryID = nil
            }
            if updated.recentManagedLibraryID == libraryID {
                updated.recentManagedLibraryID = updated.libraries.last(where: {
                    $0.modeProjection == .managed
                })?.id
            }
            if updated.recentReferencedLibraryID == libraryID {
                updated.recentReferencedLibraryID = updated.libraries.last(where: {
                    $0.modeProjection == .referenced
                })?.id
            }
        }
    }

    func completeFactoryDefaultReplacement(
        libraryID: UUID,
        defaultRootURL: URL = LibraryLocationStore.defaultLibraryRootURL
    ) throws {
        try commit { updated in
            guard updated.pendingFactoryDefaultReplacement == true,
                  updated.activeLibraryID == libraryID,
                  let descriptor = updated.library(id: libraryID),
                  URL(fileURLWithPath: descriptor.lastKnownPath).standardizedFileURL.path
                    == defaultRootURL.standardizedFileURL.path else { return }
            updated.pendingFactoryDefaultReplacement = nil
        }
    }

    /// Applies `mutation` to the newest on-disk snapshot while holding the
    /// cross-process lock, so two App processes registering different
    /// libraries both survive and row-scoped preconditions still fail closed.
    private func commit(_ mutation: (inout MusicLibraryRegistry) throws -> Void) throws {
        if let startupFailure { throw MusicLibraryRegistryError.unavailable(startupFailure) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockURL = fileURL.appendingPathExtension("lock")
        let fd = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(fd) }
        var lockInfo = stat()
        guard fstat(fd, &lockInfo) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard lockInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw MusicLibraryRegistryError.registryLocked
        }
        guard kmgccc_flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw MusicLibraryRegistryError.registryLocked }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = kmgccc_flock(fd, LOCK_UN) }
        func lockPathStillMatchesAcquiredLock() -> Bool {
            var pathInfo = stat()
            return lstat(lockURL.path, &pathInfo) == 0
                && pathInfo.st_dev == lockInfo.st_dev
                && pathInfo.st_ino == lockInfo.st_ino
        }
        guard lockPathStillMatchesAcquiredLock() else {
            throw MusicLibraryRegistryError.registryLocked
        }
        let current = try MusicLibraryRegistryFile.load(from: fileURL)
        registry = current
        var updated = current
        try mutation(&updated)
        // The mutation already matches the durable state. Reporting success
        // without an unnecessary rewrite also keeps a no-op selection from
        // consuming a pending write failure.
        guard updated != current else { return }
        try beforeCommit()
        // Re-check immediately before the rename: a replacement after this
        // point cannot be observed by advisory locking at all, and refusing
        // here keeps the detectable window as small as the write itself.
        guard lockPathStillMatchesAcquiredLock() else {
            throw MusicLibraryRegistryError.registryLocked
        }
        try MusicLibraryRegistryFile.save(updated, to: fileURL)
        registry = updated
    }
}

nonisolated extension MusicLibraryBookmark {
    static func make(
        manifest: MusicLibraryManifest,
        rootURL: URL,
        bookmarkData: Data? = nil
    ) throws -> MusicLibraryBookmark {
        let data = try bookmarkData ?? rootURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return MusicLibraryBookmark(
            id: manifest.libraryID,
            displayName: manifest.displayName,
            rootBookmarkData: data,
            lastKnownPath: rootURL.standardizedFileURL.path,
            modeProjection: manifest.mode
        )
    }
}
