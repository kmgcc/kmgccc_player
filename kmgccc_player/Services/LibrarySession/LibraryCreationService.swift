import Foundation

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
    func directoryIsEmpty(at url: URL) async throws -> Bool
    func createStagedLibrary(at url: URL, manifest: MusicLibraryManifest) async throws
    func validateLibrary(at url: URL, expectedID: UUID, expectedMode: MusicLibraryMode) async throws
    /// Recreates missing library scaffolding (required directories and the
    /// default scoped-settings file) without touching user data. Used to make
    /// libraries migrated from the pre-manifest layout openable again.
    func repairLibraryScaffolding(at url: URL) async throws
    func publishStaging(at stagingURL: URL, to destinationURL: URL) async throws
    func removeItemIfPresent(at url: URL) async
    func relocate(from sourceURL: URL, toStaging stagingURL: URL) async throws -> LibraryRelocationTransfer
    func captureRelocationAuthority(at url: URL) async throws -> LibraryRelocationAuthoritySnapshot
    func validateRelocation(at url: URL, expectedAuthority: LibraryRelocationAuthoritySnapshot, expectedID: UUID, expectedMode: MusicLibraryMode) async throws
    func rollbackRelocation(from url: URL, to sourceURL: URL, transfer: LibraryRelocationTransfer) async throws
}

nonisolated struct LibraryRelocationAuthoritySnapshot: Codable, Sendable, Equatable {
    let relativeAuthorityFiles: Set<String>
    let fileCount: Int
}

nonisolated enum LibraryRelocationTransfer: String, Codable, Sendable, Equatable {
    case sameVolume
    case copiedAcrossVolumes
}

actor ProductionLibraryLifecycleFileOperator: LibraryLifecycleFileOperating {
    private let fileManager = FileManager.default

    func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func directoryIsEmpty(at url: URL) throws -> Bool {
        try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).isEmpty
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

    func removeItemIfPresent(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
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
        let snapshot = try authoritySnapshot(at: url)
        return .init(relativeAuthorityFiles: snapshot.relativeAuthorityFiles, fileCount: snapshot.fileCount)
    }

    func validateRelocation(
        at url: URL,
        expectedAuthority: LibraryRelocationAuthoritySnapshot,
        expectedID: UUID,
        expectedMode: MusicLibraryMode
    ) throws {
        try validateLibrary(at: url, expectedID: expectedID, expectedMode: expectedMode)
        let destination = try authoritySnapshot(at: url)
        guard expectedAuthority.relativeAuthorityFiles == destination.relativeAuthorityFiles,
              expectedAuthority.fileCount == destination.fileCount else {
            throw LibraryRelocationError.validationFailed
        }
        for database in destination.sqliteFiles {
            guard try sqliteIntegrityCheck(database) else {
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
            try fileManager.removeItem(at: url)
        }
    }

    private func authoritySnapshot(at root: URL) throws -> (relativeAuthorityFiles: Set<String>, fileCount: Int, sqliteFiles: [URL]) {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { throw LibraryRelocationError.validationFailed }
        var authority = Set<String>()
        var count = 0
        var databases: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            count += 1
            let relative = String(fileURL.path.dropFirst(root.path.count + 1))
            if relative == MusicLibraryManifest.fileName || relative.hasSuffix("/meta.json") || relative.hasSuffix("/source.json") || relative.hasPrefix("Settings/") || relative.hasPrefix("Playlists/") {
                authority.insert(relative)
            }
            if fileURL.pathExtension == "sqlite" { databases.append(fileURL) }
        }
        return (authority, count, databases)
    }

    private func sqliteIntegrityCheck(_ url: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, "PRAGMA integrity_check;"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
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

        // The picker asks for the directory that should contain the fixed
        // library root. Users can still navigate into an existing
        // `kmgccc_player Library` and choose that root itself. Treat that as
        // selecting the existing library instead of silently creating a
        // nested `kmgccc_player Library/kmgccc_player Library`.
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

        // Resolve the destination directory. The preferred name is the
        // shared rootDirectoryName. Interactive creation keeps the default
        // false and reports the concrete existing library to the wizard; only
        // the system factory-default recovery path opts into a numbered
        // sibling so it can guarantee a usable empty library without
        // overwriting user data.
        var destination = parentURL
            .appendingPathComponent(LibraryPaths.rootDirectoryName, isDirectory: true)
            .standardizedFileURL
        var suffix = 1
        while await fileOperator.itemExists(at: destination) {
            try Task.checkCancellation()
            do {
                let inspected = try await openService.inspect(
                    selectedURL: destination,
                    allowStalePathConflictRepair: allowStalePathConflictRepair
                )
                guard allowAlternateDestinationWhenOccupied else {
                    return inspected.context.mode == mode
                        ? .existingLibrary(inspected.context)
                        : .existingLibraryModeMismatch(inspected.context, requestedMode: mode)
                }
                suffix += 1
                destination = parentURL
                    .appendingPathComponent("\(LibraryPaths.rootDirectoryName) \(suffix)", isDirectory: true)
                    .standardizedFileURL
            } catch {
                // Never delete or overwrite unknown user data. Explicitly
                // opting into an alternate destination (used by the system
                // fallback and the confirmation button) moves to the next
                // sibling; ordinary creation still reports the conflict.
                if allowAlternateDestinationWhenOccupied,
                   (try? await fileOperator.directoryIsEmpty(at: destination)) != true {
                    suffix += 1
                    destination = parentURL
                        .appendingPathComponent("\(LibraryPaths.rootDirectoryName) \(suffix)", isDirectory: true)
                        .standardizedFileURL
                    continue
                }
                guard (try? await fileOperator.directoryIsEmpty(at: destination)) == true else {
                    throw LibraryCreationError.destinationContainsUnknownItems
                }
                await fileOperator.removeItemIfPresent(at: destination)
                break
            }
        }

        let staging = parentURL.appendingPathComponent(".kmgccc-player-library-\(UUID().uuidString)", isDirectory: true)
        let manifest = MusicLibraryManifest(displayName: trimmedName, mode: mode)
        do {
            try await fileOperator.createStagedLibrary(at: staging, manifest: manifest)
            try await fileOperator.validateLibrary(at: staging, expectedID: manifest.libraryID, expectedMode: mode)
            try Task.checkCancellation()
            try await fileOperator.publishStaging(at: staging, to: destination)
            try Task.checkCancellation()
        } catch is CancellationError {
            await fileOperator.removeItemIfPresent(at: staging)
            await fileOperator.removeItemIfPresent(at: destination)
            throw CancellationError()
        } catch {
            await fileOperator.removeItemIfPresent(at: staging)
            throw LibraryCreationError.stagingFailed
        }

        do {
            try Task.checkCancellation()
            let inspection = try await openService.inspect(
                selectedURL: destination,
                allowStalePathConflictRepair: allowStalePathConflictRepair
            )
            try Task.checkCancellation()
            let opened = try await openService.commitActivation(inspection, gateAlreadyHeld: true)
            return .created(opened.context, initialImport: initialImport)
        } catch LibraryOpenError.recoveryFailed {
            throw LibraryCreationError.recoveryFailed
        } catch {
            await fileOperator.removeItemIfPresent(at: destination)
            throw LibraryCreationError.sessionActivationFailed
        }
    }
}
