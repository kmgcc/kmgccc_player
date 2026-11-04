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

@MainActor
final class ImportSession {
    let id: UUID
    let stagingDirectoryURL: URL

    private(set) var stagedTrackFiles: [UUID: ImportStagedTrackFile] = [:]
    private var stagedAssets: [UUID: [ImportStagedAssetFile]] = [:]
    private var generatedReferencedAudioFiles: [UUID: (url: URL, fingerprint: ReferencedFileFingerprint)] = [:]
    private(set) var finalizedTrackIDs: Set<UUID> = []
    private(set) var committedTrackIDs: Set<UUID> = []

    init(
        id: UUID = UUID(),
        paths: LibraryPaths,
        fileManager: FileManager = .default
    ) throws {
        self.id = id
        let root = paths.importStagingRootURL
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

    func cleanupStaging(fileManager: FileManager = .default) {
        removeGeneratedReferencedAudio(
            for: Set(generatedReferencedAudioFiles.keys).subtracting(committedTrackIDs),
            fileManager: fileManager
        )
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
        var deletedFolders = 0
        var failedFolders = 0
        if !fileTrackIDs.isEmpty {
            // Folder deletion is pure FileManager work; run it off the main
            // actor so large rollbacks cannot block the UI. `deleteTrackFolder`
            // is nonisolated and only reads immutable state, so it is safe to
            // call off main.
            let deletionService = libraryService
            let trackIDs = Array(fileTrackIDs)
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
