//
//  ImportSession.swift
//  myPlayer2
//
//  Small import-session primitives used by FileImportService.
//

import Foundation

actor ImportCancellationToken {
    private var cancelled = false

    func requestCancel() {
        cancelled = true
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

@MainActor
final class ImportSession {
    let id: UUID
    let stagingDirectoryURL: URL

    private(set) var stagedTrackFiles: [UUID: ImportStagedTrackFile] = [:]
    private(set) var finalizedTrackIDs: Set<UUID> = []
    private(set) var committedTrackIDs: Set<UUID> = []

    init(id: UUID = UUID(), fileManager: FileManager = .default) throws {
        self.id = id
        let root = LocalLibraryPaths.libraryRootURL
            .appendingPathComponent("ImportStaging", isDirectory: true)
        self.stagingDirectoryURL = root
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: stagingDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    func registerStagedTrack(_ file: ImportStagedTrackFile) {
        stagedTrackFiles[file.trackID] = file
    }

    func stagedFiles(for trackIDs: Set<UUID>) -> [ImportStagedTrackFile] {
        trackIDs.compactMap { stagedTrackFiles[$0] }
    }

    func markFinalized(trackIDs: [UUID]) {
        finalizedTrackIDs.formUnion(trackIDs)
    }

    func markCommitted(trackIDs: [UUID]) {
        committedTrackIDs.formUnion(trackIDs)
    }

    func cleanupStaging(fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: stagingDirectoryURL.path) else { return }
        do {
            try fileManager.removeItem(at: stagingDirectoryURL)
        } catch {
            Log.warning(
                "[ImportSession] failed to cleanup staging session=\(id.uuidString): \(error.localizedDescription)",
                category: .import
            )
        }
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
            await repository.deleteTracks(tracksToDelete)
            Log.info(
                "[ImportRollback] repository rollback reason=\(reason) tracks=\(tracksToDelete.count)",
                category: .import
            )
        }

        let fileTrackIDs = createdTrackIDs
            .union(session.finalizedTrackIDs)
            .union(committedIDs)
        var deletedFolders = 0
        var failedFolders = 0
        for trackID in fileTrackIDs {
            if libraryService.deleteTrackFolder(trackID: trackID) {
                deletedFolders += 1
            } else {
                failedFolders += 1
            }
        }

        session.cleanupStaging()

        return ImportRollbackReport(
            deletedDatabaseTrackCount: tracksToDelete.count,
            deletedTrackFolderCount: deletedFolders,
            failedTrackFolderDeleteCount: failedFolders
        )
    }
}
