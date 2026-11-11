import Foundation
import Darwin
import CryptoKit

nonisolated struct LibraryInitialImportPayload: Sendable, Equatable {
    let selectedURLs: [URL]

    init(selectedURLs: [URL] = []) {
        self.selectedURLs = selectedURLs
    }
}

nonisolated enum LibraryCreationResult: Sendable, Equatable {
    case created(LibraryContext, initialImport: LibraryInitialImportPayload)
    case existingLibrary(LibraryContext)
    case existingLibraryModeMismatch(LibraryContext, requestedMode: MusicLibraryMode)
}

nonisolated enum LibraryCreationError: Error, Equatable {
    case invalidDisplayName
    case destinationContainsUnknownItems
    case invalidExistingLibrary
    case stagingFailed
    case validationFailed
    case registryCommitFailed
    case sessionActivationFailed
    case recoveryFailed
}

nonisolated protocol LibraryLifecycleFileOperating: Sendable {
    func itemExists(at url: URL) async -> Bool
    func removeEmptyDirectory(at url: URL) async throws
    func createStagedLibrary(at url: URL, manifest: MusicLibraryManifest) async throws
    func validateLibrary(at url: URL, expectedID: UUID, expectedMode: MusicLibraryMode) async throws
    /// Recreates missing library scaffolding (required directories and the
    /// default scoped-settings file) without touching user data. Used to make
    /// libraries migrated from the pre-manifest layout openable again.
    func repairLibraryScaffolding(at url: URL) async throws
    func publishStaging(at stagingURL: URL, to destinationURL: URL) async throws
    /// Renames a staging directory created by this transaction and deletes it
    /// only after re-reading the manifest from the renamed path. A directory
    /// that no longer carries the expected identity is restored and retained.
    func discardOwnedStaging(at url: URL, expectedLibraryID: UUID) async throws
    func relocate(from sourceURL: URL, toStaging stagingURL: URL) async throws -> LibraryRelocationTransfer
    func captureRelocationAuthority(at url: URL) async throws -> LibraryRelocationAuthoritySnapshot
    func validateRelocation(at url: URL, expectedAuthority: LibraryRelocationAuthoritySnapshot, expectedID: UUID, expectedMode: MusicLibraryMode) async throws
    func rollbackRelocation(from url: URL, to sourceURL: URL, transfer: LibraryRelocationTransfer) async throws
}

nonisolated struct LibraryRelocationAuthoritySnapshot: Codable, Sendable, Equatable {
    let relativeAuthorityFiles: Set<String>
    let fileCount: Int
    /// Optional for repair intents created before content verification.
    let fileDigests: [String: String]?
}

nonisolated enum LibraryRelocationTransfer: String, Codable, Sendable, Equatable {
    case sameVolume
    case copiedAcrossVolumes
}

private nonisolated final class LibraryEnumerationFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var detail: String?

    func record(_ url: URL, _ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if detail == nil { detail = "\(url.path): \(error.localizedDescription)" }
    }

    func result() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return detail
    }
}

actor ProductionLibraryLifecycleFileOperator: LibraryLifecycleFileOperating {
    private let fileManager = FileManager.default
    private let sqliteExecutableURL: URL
    private let sqliteCheckTimeout: TimeInterval

    init(
        sqliteExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/sqlite3"),
        sqliteCheckTimeout: TimeInterval = 60
    ) {
        self.sqliteExecutableURL = sqliteExecutableURL
        self.sqliteCheckTimeout = max(0.1, sqliteCheckTimeout)
    }

    func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func removeEmptyDirectory(at url: URL) throws {
        guard Darwin.rmdir(url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func createStagedLibrary(at url: URL, manifest: MusicLibraryManifest) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        let paths = LibraryPaths(rootURL: url)
        try paths.createRequiredDirectories(fileManager: fileManager)
        try manifest.write(to: paths.manifestURL, fileManager: fileManager)
        try LibraryScopedSettingsFile.save(
            LibraryScopedSettings(),
            to: paths.librarySettingsURL,
            fileManager: fileManager
        )
    }

    func validateLibrary(at url: URL, expectedID: UUID, expectedMode: MusicLibraryMode) throws {
        let paths = LibraryPaths(rootURL: url)
        let manifest = try MusicLibraryManifest.read(from: paths.manifestURL)
        guard manifest.libraryID == expectedID else { throw LibraryCreationError.validationFailed }
        guard manifest.mode == expectedMode else { throw LibraryCreationError.validationFailed }
        for required in paths.requiredDirectories {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: required.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw LibraryCreationError.validationFailed
            }
        }
        guard fileManager.fileExists(atPath: paths.librarySettingsURL.path) else {
            throw LibraryCreationError.validationFailed
        }
    }

    func repairLibraryScaffolding(at url: URL) throws {
        try LibraryScaffoldingRepair.repairIfNeeded(at: url, fileManager: fileManager)
    }

    func publishStaging(at stagingURL: URL, to destinationURL: URL) throws {
        try fileManager.moveItem(at: stagingURL, to: destinationURL)
    }

    func discardOwnedStaging(at url: URL, expectedLibraryID: UUID) async throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let discardURL = url.deletingLastPathComponent()
            .appendingPathComponent(".kmgccc-player-discard-\(UUID().uuidString)", isDirectory: true)
        try fileManager.moveItem(at: url, to: discardURL)
        do {
            let manifest = try MusicLibraryManifest.read(from: LibraryPaths(rootURL: discardURL).manifestURL)
            guard manifest.libraryID == expectedLibraryID else {
                throw LibraryCreationError.validationFailed
            }
            try fileManager.removeItem(at: discardURL)
        } catch {
            // The renamed directory no longer matches what this transaction
            // created. Put it back at its original name when that path is
            // still free; otherwise keep the renamed copy for inspection.
            if !fileManager.fileExists(atPath: url.path) {
                try? fileManager.moveItem(at: discardURL, to: url)
            } else {
                Log.warning(
                    "[LibraryCreation] staging kept at \(discardURL.path); original path was recreated",
                    category: .library
                )
            }
            throw error
        }
    }

    func relocate(from sourceURL: URL, toStaging stagingURL: URL) throws -> LibraryRelocationTransfer {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        let sourceVolume = try sourceURL.resourceValues(forKeys: keys).volumeIdentifier
        let destinationVolume = try stagingURL.deletingLastPathComponent().resourceValues(forKeys: keys).volumeIdentifier
        if let sourceVolume, let destinationVolume,
           String(describing: sourceVolume) == String(describing: destinationVolume) {
            try fileManager.moveItem(at: sourceURL, to: stagingURL)
            return .sameVolume
        }
        try fileManager.copyItem(at: sourceURL, to: stagingURL)
        return .copiedAcrossVolumes
    }

    func captureRelocationAuthority(at url: URL) throws -> LibraryRelocationAuthoritySnapshot {
        let snapshot = try authoritySnapshot(at: url, includeHidden: true)
        return .init(relativeAuthorityFiles: snapshot.relativeAuthorityFiles, fileCount: snapshot.fileCount, fileDigests: snapshot.fileDigests)
    }

    func validateRelocation(
        at url: URL,
        expectedAuthority: LibraryRelocationAuthoritySnapshot,
        expectedID: UUID,
        expectedMode: MusicLibraryMode
    ) async throws {
        try validateLibrary(at: url, expectedID: expectedID, expectedMode: expectedMode)
        let destination = try authoritySnapshot(at: url, includeHidden: expectedAuthority.fileDigests != nil)
        guard expectedAuthority.relativeAuthorityFiles == destination.relativeAuthorityFiles,
              expectedAuthority.fileCount == destination.fileCount,
              expectedAuthority.fileDigests == nil || expectedAuthority.fileDigests == destination.fileDigests else {
            throw LibraryRelocationError.validationFailed
        }
        for database in destination.sqliteFiles {
            guard try await sqliteIntegrityCheck(database) else {
                throw LibraryRelocationError.validationFailed
            }
        }
    }

    func rollbackRelocation(from url: URL, to sourceURL: URL, transfer: LibraryRelocationTransfer) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        switch transfer {
        case .sameVolume:
            guard !fileManager.fileExists(atPath: sourceURL.path) else {
                throw LibraryRelocationError.recoveryFailed
            }
            try fileManager.moveItem(at: url, to: sourceURL)
        case .copiedAcrossVolumes:
            // Published copies can have been modified independently after
            // validation. Retain the copy and the repair intent for review.
            throw LibraryRelocationError.recoveryFailed
        }
    }

    private func authoritySnapshot(at root: URL, includeHidden: Bool) throws -> (relativeAuthorityFiles: Set<String>, fileCount: Int, fileDigests: [String: String], sqliteFiles: [URL]) {
        let enumerationFailure = LibraryEnumerationFailure()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: includeHidden ? [] : [.skipsHiddenFiles],
            errorHandler: { url, error in
                enumerationFailure.record(url, error)
                return false
            }
        ) else { throw LibraryRelocationError.validationFailed }
        var authority = Set<String>()
        var count = 0
        var digests: [String: String] = [:]
        var databases: [URL] = []
        // The enumerator's URLs can carry a different spelling of the root
        // (`/var` versus `/private/var`). Derive the relative path from the
        // enumerator depth instead of a character offset, so capture and
        // validation produce the same keys for the same tree.
        while let fileURL = enumerator.nextObject() as? URL {
            let level = enumerator.level
            var info = stat()
            guard lstat(fileURL.path, &info) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let fileType = info.st_mode & mode_t(S_IFMT)
            if fileType == mode_t(S_IFDIR) { continue }
            guard fileType == mode_t(S_IFREG) || fileType == mode_t(S_IFLNK),
                  level > 0 else {
                throw LibraryRelocationError.validationFailed
            }
            let components = fileURL.pathComponents
            guard components.count >= level else {
                throw LibraryRelocationError.validationFailed
            }
            let relative = components.suffix(level).joined(separator: "/")
            // Exclude the session lock regardless of how the root is spelled.
            if level == 2,
               components.last == ".writer.lock",
               components.dropLast().last == "Settings" {
                continue
            }
            count += 1
            if fileType == mode_t(S_IFLNK) {
                let target = try fileManager.destinationOfSymbolicLink(atPath: fileURL.path)
                digests[relative] = "symlink:" + target
                continue
            }
            // Open without following a replacement symlink and without
            // blocking if the path was replaced by a FIFO after lstat.
            let fd = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var hash = SHA256()
            do {
                var opened = stat()
                guard fstat(fd, &opened) == 0,
                      opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
                    throw LibraryRelocationError.validationFailed
                }
                while true {
                    try Task.checkCancellation()
                    let chunk = try input.read(upToCount: 1_048_576) ?? Data()
                    if chunk.isEmpty { break }
                    hash.update(data: chunk)
                }
                var finished = stat()
                guard fstat(fd, &finished) == 0,
                      finished.st_size == opened.st_size,
                      finished.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
                      finished.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec,
                      finished.st_ctimespec.tv_sec == opened.st_ctimespec.tv_sec,
                      finished.st_ctimespec.tv_nsec == opened.st_ctimespec.tv_nsec else {
                    throw LibraryRelocationError.validationFailed
                }
                try input.close()
            } catch {
                try? input.close()
                throw error
            }
            digests[relative] = hash.finalize().map { String(format: "%02x", $0) }.joined()
            if relative == MusicLibraryManifest.fileName || relative.hasSuffix("/meta.json") || relative.hasSuffix("/source.json") || relative.hasPrefix("Settings/") || relative.hasPrefix("Playlists/") {
                authority.insert(relative)
            }
            if fileURL.pathExtension == "sqlite" { databases.append(fileURL) }
        }
        if let failure = enumerationFailure.result() {
            Log.error("[LibraryRelocation] directory enumeration failed: \(failure)", category: .library)
            throw LibraryRelocationError.validationFailed
        }
        return (authority, count, digests, databases)
    }

    private func sqliteIntegrityCheck(_ url: URL) async throws -> Bool {
        // A damaged database can emit more than a pipe buffer. Redirect to a
        // temporary file so neither output stream can block process exit.
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("library-integrity-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            throw LibraryRelocationError.validationFailed
        }
        defer { try? fileManager.removeItem(at: outputURL) }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        let process = Process()
        process.executableURL = sqliteExecutableURL
        // One integrity error is enough to reject the copy and bounds normal
        // sqlite output even for a severely damaged database.
        process.arguments = [url.path, "PRAGMA integrity_check(1);"]
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        try process.run()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(sqliteCheckTimeout))
        do {
            while process.isRunning {
                try Task.checkCancellation()
                var outputInfo = stat()
                guard fstat(outputHandle.fileDescriptor, &outputInfo) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if outputInfo.st_size > 65_536 {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    return false
                }
                guard clock.now < deadline else {
                    kill(process.processIdentifier, SIGKILL)
                    return false
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw error
        }
        let input = try FileHandle(forReadingFrom: outputURL)
        defer { try? input.close() }
        let outputData = try input.read(upToCount: 1024) ?? Data()
        guard outputData.count < 1024 else { return false }
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && output == "ok"
    }
}

@MainActor
final class LibraryCreationService {
    private let openService: LibraryOpenService
    private let fileOperator: any LibraryLifecycleFileOperating
    private let gate: LibraryLifecycleTransactionGate

    init(
        registryStore: MusicLibraryRegistryStore,
        openService: LibraryOpenService,
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        fileOperator: any LibraryLifecycleFileOperating = ProductionLibraryLifecycleFileOperator(),
        gate: LibraryLifecycleTransactionGate = LibraryLifecycleTransactionGate(),
        initialGeneration: UInt64 = 1
    ) {
        _ = registryStore
        _ = bookmarkResolver
        _ = initialGeneration
        self.openService = openService
        self.fileOperator = fileOperator
        self.gate = gate
    }

    func create(
        mode: MusicLibraryMode,
        parentURL: URL,
        displayName: String,
        factoryDefaultRoot: Bool = false,
        initialImport: LibraryInitialImportPayload = .init(),
        allowAlternateDestinationWhenOccupied: Bool = false,
        allowStalePathConflictRepair: Bool = false
    ) async throws -> LibraryCreationResult {
        try Task.checkCancellation()
        do { try gate.acquire() }
        catch { throw LibraryCreationError.stagingFailed }
        defer { gate.release() }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw LibraryCreationError.invalidDisplayName }

        // Selecting a library root itself still means opening that library,
        // including roots created by older versions. Never nest a new library
        // inside it.
        let selectedParent = parentURL.standardizedFileURL
        let selectedRootManifest = LibraryPaths(rootURL: selectedParent).manifestURL
        if await fileOperator.itemExists(at: selectedRootManifest) {
            do {
                let inspected = try await openService.inspect(
                    selectedURL: selectedParent,
                    allowStalePathConflictRepair: allowStalePathConflictRepair
                )
                return inspected.context.mode == mode
                    ? .existingLibrary(inspected.context)
                    : .existingLibraryModeMismatch(inspected.context, requestedMode: mode)
            } catch {
                throw LibraryCreationError.invalidExistingLibrary
            }
        }

        // Different names share a parent without sharing a library root.
        // The wizard may choose a numbered sibling when a destination is
        // occupied. The controlled factory default keeps its exact path.
        let directoryName = factoryDefaultRoot
            ? LibraryPaths.rootDirectoryName
            : LibraryPaths.newLibraryDirectoryName(for: trimmedName)
        var destination = selectedParent
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
        var suffix = 1
        while await fileOperator.itemExists(at: destination) {
            try Task.checkCancellation()
            if allowAlternateDestinationWhenOccupied, !factoryDefaultRoot {
                suffix += 1
                destination = selectedParent
                    .appendingPathComponent("\(directoryName) \(suffix)", isDirectory: true)
                    .standardizedFileURL
                continue
            }
            do {
                let inspected = try await openService.inspect(
                    selectedURL: destination,
                    allowStalePathConflictRepair: allowStalePathConflictRepair
                )
                return inspected.context.mode == mode
                    ? .existingLibrary(inspected.context)
                    : .existingLibraryModeMismatch(inspected.context, requestedMode: mode)
            } catch {
                do { try await fileOperator.removeEmptyDirectory(at: destination) }
                catch {
                    throw LibraryCreationError.destinationContainsUnknownItems
                }
                break
            }
        }

        let staging = parentURL.appendingPathComponent(".kmgccc-player-library-\(UUID().uuidString)", isDirectory: true)
        let manifest = MusicLibraryManifest(displayName: trimmedName, mode: mode)
        var didPublish = false
        do {
            try await fileOperator.createStagedLibrary(at: staging, manifest: manifest)
            try await fileOperator.validateLibrary(at: staging, expectedID: manifest.libraryID, expectedMode: mode)
            try Task.checkCancellation()
            try await fileOperator.publishStaging(at: staging, to: destination)
            didPublish = true
            try Task.checkCancellation()
        } catch is CancellationError {
            await discardStagingIfOwned(at: staging, manifest: manifest)
            if didPublish { await removeCreatedLibrary(at: destination, manifest: manifest) }
            throw CancellationError()
        } catch {
            await discardStagingIfOwned(at: staging, manifest: manifest)
            throw LibraryCreationError.stagingFailed
        }

        do {
            try Task.checkCancellation()
            let inspection = try await openService.inspect(
                selectedURL: destination,
                allowStalePathConflictRepair: allowStalePathConflictRepair
            )
            guard inspection.context.id == manifest.libraryID,
                  inspection.context.mode == manifest.mode else {
                throw LibraryCreationError.validationFailed
            }
            try Task.checkCancellation()
            let opened = try await openService.commitActivation(inspection, gateAlreadyHeld: true)
            return .created(opened.context, initialImport: initialImport)
        } catch LibraryOpenError.recoveryFailed {
            throw LibraryCreationError.recoveryFailed
        } catch is CancellationError {
            await removeCreatedLibrary(at: destination, manifest: manifest)
            throw CancellationError()
        } catch {
            await removeCreatedLibrary(at: destination, manifest: manifest)
            throw LibraryCreationError.sessionActivationFailed
        }
    }

    private func removeCreatedLibrary(at root: URL, manifest: MusicLibraryManifest) async {
        // Once published, another process can modify or replace this path.
        // A prior manifest check cannot authorize a later recursive deletion.
        Log.warning("[LibraryCreation] retaining published library after failed activation id=\(manifest.libraryID) root=\(root.path)", category: .library)
    }

    private func discardStagingIfOwned(at url: URL, manifest: MusicLibraryManifest) async {
        guard await fileOperator.itemExists(at: url) else { return }
        do {
            try await fileOperator.discardOwnedStaging(
                at: url,
                expectedLibraryID: manifest.libraryID
            )
        } catch {
            Log.warning(
                "[LibraryCreation] retaining staging directory after interrupted creation root=\(url.path) error=\(error.localizedDescription)",
                category: .library
            )
        }
    }
}
