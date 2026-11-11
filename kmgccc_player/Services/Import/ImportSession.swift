//
//  ImportSession.swift
//  myPlayer2
//
//  Small import-session primitives used by FileImportService.
//

import Foundation

actor ImportCancellationToken {
    private var cancelled = false
    private var cancellationHandlers: [UUID: @Sendable () -> Void] = [:]

    func requestCancel() {
        cancelled = true
        let handlers = cancellationHandlers.values
        cancellationHandlers.removeAll()
        for handler in handlers { handler() }
    }

    func registerCancellationHandler(_ handler: @escaping @Sendable () -> Void) throws -> UUID {
        try checkCancellation()
        let id = UUID()
        cancellationHandlers[id] = handler
        return id
    }

    func removeCancellationHandler(_ id: UUID) {
        cancellationHandlers.removeValue(forKey: id)
    }

    var isCancelled: Bool {
        cancelled
    }

    func checkCancellation() throws {
        if cancelled || Task.isCancelled {
            throw CancellationError()
        }
    }
}

nonisolated enum ImportConcurrencyLimiter {
    static func audioPreparationConcurrency(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        let cpuCount = max(1, ProcessInfo.processInfo.processorCount)
        return min(count, min(8, max(3, cpuCount)))
    }

    static func metadataReadConcurrency(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        let cpuCount = max(1, ProcessInfo.processInfo.processorCount)
        return min(count, min(10, max(4, cpuCount * 2)))
    }

    static func ncmConversionConcurrency(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        let cpuCount = max(1, ProcessInfo.processInfo.processorCount)
        return min(count, min(6, max(2, cpuCount)))
    }

    static func networkEnrichmentConcurrency(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        return min(count, 4)
    }

    static var databaseCommitConcurrency: Int { 1 }
}

struct ImportStagedTrackFile: Sendable {
    let trackID: UUID
    let stagedAudioURL: URL
    let libraryRelativePath: String
}

nonisolated struct ImportStagedAssetFile: Sendable {
    let stagedURL: URL
    let libraryRelativePath: String
}

nonisolated struct ImportStagingMarker: Codable, Sendable, Equatable {
    static let fileName = ".session.json"
    static let schemaVersion = 1

    let schemaVersion: Int
    let sessionID: UUID
    let createdAt: Date

    init(sessionID: UUID, createdAt: Date = Date()) {
        schemaVersion = Self.schemaVersion
        self.sessionID = sessionID
        self.createdAt = createdAt
    }
}

/// Proves that an unreferenced managed track folder was created by an import
/// session. Residue cleanup deletes only folders carrying this marker for the
/// same track identifier, so a folder a user prepared in advance is retained.
nonisolated struct ImportTrackFolderMarker: Codable, Sendable, Equatable {
    static let fileName = ".import-owner.json"
    static let schemaVersion = 1

    let schemaVersion: Int
    let trackID: UUID
    let sessionID: UUID
    let createdAt: Date

    init(trackID: UUID, sessionID: UUID, createdAt: Date = Date()) {
        schemaVersion = Self.schemaVersion
        self.trackID = trackID
        self.sessionID = sessionID
        self.createdAt = createdAt
    }

    static func marksOwnership(
        of folderURL: URL,
        trackID: UUID,
        fileManager: FileManager = .default
    ) -> Bool {
        let markerURL = folderURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: markerURL) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let marker = try? decoder.decode(ImportTrackFolderMarker.self, from: data) else {
            return false
        }
        return marker.schemaVersion == Self.schemaVersion && marker.trackID == trackID
    }

    func write(to folderURL: URL, fileManager: FileManager = .default) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(
            to: folderURL.appendingPathComponent(Self.fileName),
            options: .atomic
        )
    }
}

@MainActor
final class ImportSession {
    let id: UUID
    let stagingDirectoryURL: URL
    private let fileManager: FileManager

    private(set) var stagedTrackFiles: [UUID: ImportStagedTrackFile] = [:]
    private var stagedAssets: [UUID: [ImportStagedAssetFile]] = [:]
    private var generatedReferencedAudioFiles: [UUID: (url: URL, fingerprint: ReferencedFileFingerprint)] = [:]
    private(set) var finalizedTrackIDs: Set<UUID> = []
    private(set) var committedTrackIDs: Set<UUID> = []
    private(set) var retainedTrackFolderIDs: Set<UUID> = []

    init(
        id: UUID = UUID(),
        paths: LibraryPaths,
        fileManager: FileManager = .default
    ) throws {
        self.id = id
        self.fileManager = fileManager
        let root = paths.importStagingRootURL
        self.stagingDirectoryURL = root
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: stagingDirectoryURL,
            withIntermediateDirectories: true
        )
        // The marker proves this exact directory belongs to this session, so
        // cleanup can refuse a path that was replaced by something else.
        let marker = ImportStagingMarker(sessionID: id)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(
            to: stagingDirectoryURL.appendingPathComponent(ImportStagingMarker.fileName),
            options: .atomic
        )
    }

    func registerStagedTrack(_ file: ImportStagedTrackFile) {
        stagedTrackFiles[file.trackID] = file
    }

    func stagedFiles(for trackIDs: Set<UUID>) -> [ImportStagedTrackFile] {
        trackIDs.compactMap { stagedTrackFiles[$0] }
    }

    func registerStagedAssets(_ assets: [ImportStagedAssetFile], for trackID: UUID, generatedAudioURL: URL?) {
        stagedAssets[trackID] = assets
        if let url = generatedAudioURL,
           let fingerprint = try? ReferencedFileIdentityProvider().fingerprint(for: url) {
            generatedReferencedAudioFiles[trackID] = (url, fingerprint)
        }
    }

    func stagedAssetFiles(for trackIDs: Set<UUID>) -> [ImportStagedAssetFile] {
        trackIDs.flatMap { stagedAssets[$0] ?? [] }
    }

    func removeGeneratedReferencedAudio(for trackIDs: Set<UUID>, fileManager: FileManager = .default) {
        for trackID in trackIDs {
            guard let file = generatedReferencedAudioFiles.removeValue(forKey: trackID),
                  let current = try? ReferencedFileIdentityProvider().fingerprint(for: file.url),
                  current == file.fingerprint else { continue }
            do {
                try fileManager.removeItem(at: file.url)
            } catch {
                Log.warning("[ImportSession] failed to remove generated video audio track=\(trackID): \(error.localizedDescription)", category: .import)
            }
        }
    }

    func markFinalized(trackIDs: [UUID]) {
        finalizedTrackIDs.formUnion(trackIDs)
    }

    func markCommitted(trackIDs: [UUID]) {
        committedTrackIDs.formUnion(trackIDs)
    }

    func retainTrackFolders(trackIDs: [UUID]) {
        retainedTrackFolderIDs.formUnion(trackIDs)
    }

    func cleanupStaging(fileManager: FileManager = .default) {
        removeGeneratedReferencedAudio(
            for: Set(generatedReferencedAudioFiles.keys).subtracting(committedTrackIDs),
            fileManager: fileManager
        )
        guard fileManager.fileExists(atPath: stagingDirectoryURL.path) else { return }
        guard stagingDirectoryIsOwned(by: id, fileManager: fileManager) else {
            Log.warning(
                "[ImportSession] retaining staging directory whose marker does not match session=\(id.uuidString)",
                category: .import
            )
            return
        }
        // Rename first: content written to the old path afterwards belongs to
        // a new directory and is never part of this deletion.
        let discardURL = stagingDirectoryURL.deletingLastPathComponent()
            .appendingPathComponent(".discard-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.moveItem(at: stagingDirectoryURL, to: discardURL)
            try fileManager.removeItem(at: discardURL)
        } catch {
            Log.warning(
                "[ImportSession] failed to cleanup staging session=\(id.uuidString): \(error.localizedDescription)",
                category: .import
            )
        }
    }

    private func stagingDirectoryIsOwned(by sessionID: UUID, fileManager: FileManager) -> Bool {
        let markerURL = stagingDirectoryURL.appendingPathComponent(ImportStagingMarker.fileName)
        guard let data = try? Data(contentsOf: markerURL) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let marker = try? decoder.decode(ImportStagingMarker.self, from: data) else { return false }
        return marker.schemaVersion == ImportStagingMarker.schemaVersion
            && marker.sessionID == sessionID
    }
}

struct ImportRollbackReport: Sendable {
    let deletedDatabaseTrackCount: Int
    let deletedTrackFolderCount: Int
    let failedTrackFolderDeleteCount: Int
}

@MainActor
struct ImportRollbackService {
    let repository: LibraryRepositoryProtocol
    let libraryService: LocalLibraryService

    func rollback(
        session: ImportSession,
        importedTracks: [Track],
        createdTrackIDs: Set<UUID>,
        reason: String
    ) async -> ImportRollbackReport {
        let committedIDs = session.committedTrackIDs
        let importedByID = Dictionary(uniqueKeysWithValues: importedTracks.map { ($0.id, $0) })
        var tracksToDelete = committedIDs.compactMap { importedByID[$0] }

        let missingCommittedIDs = committedIDs.subtracting(Set(tracksToDelete.map(\.id)))
        if !missingCommittedIDs.isEmpty {
            tracksToDelete.append(contentsOf: await repository.fetchTracks(ids: Array(missingCommittedIDs)))
        }

        if !tracksToDelete.isEmpty {
            do {
                try await repository.deleteTracks(tracksToDelete)
                Log.info(
                    "[ImportRollback] repository rollback reason=\(reason) tracks=\(tracksToDelete.count)",
                    category: .import
                )
            } catch {
                Log.error(
                    "[ImportRollback] repository rollback failed reason=\(reason) tracks=\(tracksToDelete.count): \(error.localizedDescription)",
                    category: .import
                )
            }
        }

        let fileTrackIDs = createdTrackIDs
            .union(session.finalizedTrackIDs)
            .union(committedIDs)
        let removableTrackIDs = fileTrackIDs.subtracting(session.retainedTrackFolderIDs)
        var deletedFolders = 0
        var failedFolders = 0
        if !removableTrackIDs.isEmpty {
            // Folder deletion is pure FileManager work; run it off the main
            // actor so large rollbacks cannot block the UI. `deleteTrackFolder`
            // is nonisolated and only reads immutable state, so it is safe to
            // call off main.
            let deletionService = libraryService
            let trackIDs = Array(removableTrackIDs)
            let counters = await Task.detached(priority: .utility) { @Sendable () -> (deleted: Int, failed: Int) in
                var deleted = 0
                var failed = 0
                for trackID in trackIDs {
                    if deletionService.deleteTrackFolder(trackID: trackID) {
                        deleted += 1
                    } else {
                        failed += 1
                    }
                }
                return (deleted, failed)
            }.value
            deletedFolders = counters.deleted
            failedFolders = counters.failed
        }

        session.removeGeneratedReferencedAudio(for: fileTrackIDs)
        session.cleanupStaging()

        return ImportRollbackReport(
            deletedDatabaseTrackCount: tracksToDelete.count,
            deletedTrackFolderCount: deletedFolders,
            failedTrackFolderDeleteCount: failedFolders
        )
    }
}
