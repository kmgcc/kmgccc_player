//
//  LibraryStorageValidator.swift
//  kmgccc_player
//
//  Strict on-disk consistency check for an open library session.
//

import Foundation
import SQLite3

nonisolated enum LibraryStorageValidationError: Error, Equatable {
    case manifestMismatch
    case damagedTrackSidecar
    case damagedPlaylistSidecar
    case duplicateTrackID
    case trackCountMismatch
    case playlistReferenceMissing
    case storageModeMismatch
    case trackIndexUnavailable
    case trackIndexMismatch
    case searchIndexMismatch
    case historyStoreMismatch
    case sqliteIntegrityFailed(String)
}

@MainActor
enum LibraryStorageValidator {
    static func validate(
        context: LibraryContext,
        libraryViewModel: LibraryViewModel,
        repository: SwiftDataLibraryRepository,
        searchIndex: LibrarySearchIndex,
        playbackHistoryStore: PlaybackHistoryStore
    ) async throws {
        guard libraryViewModel.lastLoadingError == nil,
              libraryViewModel.state == .loaded else {
            throw LibraryStorageValidationError.trackCountMismatch
        }

        let disk = try await Task.detached(priority: .utility) {
            try inspectDisk(context: context)
        }.value
        let runtimeTracks = await repository.fetchTracks(in: nil)
        let runtimeTrackIDs = Set(runtimeTracks.map(\.id))
        guard runtimeTrackIDs == disk.trackIDs else {
            throw LibraryStorageValidationError.trackCountMismatch
        }
        guard disk.playlistTrackIDs.isSubset(of: disk.trackIDs) else {
            throw LibraryStorageValidationError.playlistReferenceMissing
        }
        guard disk.locatorKinds.allSatisfy({ $0 == context.mode.storageKind }) else {
            throw LibraryStorageValidationError.storageModeMismatch
        }
        guard try repository.persistedTrackIndexIDs() == disk.trackIDs else {
            throw LibraryStorageValidationError.trackIndexMismatch
        }

        await searchIndex.waitForPendingRebuild()
        try await searchIndex.validateIntegrity(expectedTrackIDs: disk.trackIDs)
        try playbackHistoryStore.validateReadableStore(at: context.paths.playbackHistoryStoreURL)

        let manifest = try MusicLibraryManifest.read(from: context.paths.manifestURL)
        guard manifest.libraryID == context.id, manifest.mode == context.mode else {
            throw LibraryStorageValidationError.manifestMismatch
        }
        for url in [
            context.paths.trackIndexStoreURL,
            context.paths.searchIndexStoreURL,
            context.paths.playbackHistoryStoreURL,
        ] {
            try await Task.detached(priority: .utility) {
                try validateSQLite(at: url)
            }.value
        }
    }

    nonisolated struct DiskSnapshot: Sendable {
        let trackIDs: Set<UUID>
        let playlistTrackIDs: Set<UUID>
        let locatorKinds: [LocalTrackStorageKind]
        let playlistReferenceIssues: [LibraryStoragePlaylistReferenceIssue]
    }

    nonisolated struct LibraryStoragePlaylistReferenceIssue: Sendable, Equatable {
        let playlistID: UUID
        let playlistName: String
        let missingTrackIDs: [UUID]
    }

    nonisolated static func inspectDisk(
        context: LibraryContext
    ) throws -> DiskSnapshot {
        let fileManager = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var trackIDs = Set<UUID>()
        var locatorKinds: [LocalTrackStorageKind] = []

        for directory in try directDirectories(at: context.paths.tracksRootURL) {
            guard let folderID = UUID(uuidString: directory.lastPathComponent) else {
                throw LibraryStorageValidationError.damagedTrackSidecar
            }
            let metaURL = directory.appendingPathComponent("meta.json")
            guard let sidecar = try? decoder.decode(
                TrackSidecar.self,
                from: Data(contentsOf: metaURL)
            ), sidecar.id == folderID else {
                throw LibraryStorageValidationError.damagedTrackSidecar
            }
            guard trackIDs.insert(sidecar.id).inserted else {
                throw LibraryStorageValidationError.duplicateTrackID
            }
            locatorKinds.append(sidecar.mediaLocator.storageKind)
        }

        var playlistTrackIDs = Set<UUID>()
        var playlistReferenceIssues: [LibraryStoragePlaylistReferenceIssue] = []
        let playlistURLs: [URL]
        do {
            playlistURLs = try fileManager.contentsOfDirectory(
                at: context.paths.playlistsRootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw LibraryStorageValidationError.damagedPlaylistSidecar
        }
        for url in playlistURLs where url.pathExtension.lowercased() == "json" {
            guard let sidecar = try? decoder.decode(
                PlaylistSidecar.self,
                from: Data(contentsOf: url)
            ) else {
                throw LibraryStorageValidationError.damagedPlaylistSidecar
            }
            let playlistIDs = sidecar.trackIDs
            playlistTrackIDs.formUnion(playlistIDs)
            let missingTrackIDs = playlistIDs.filter { !trackIDs.contains($0) }
            if !missingTrackIDs.isEmpty {
                playlistReferenceIssues.append(
                    LibraryStoragePlaylistReferenceIssue(
                        playlistID: sidecar.id,
                        playlistName: sidecar.name,
                        missingTrackIDs: missingTrackIDs
                    )
                )
            }
        }

        return DiskSnapshot(
            trackIDs: trackIDs,
            playlistTrackIDs: playlistTrackIDs,
            locatorKinds: locatorKinds,
            playlistReferenceIssues: playlistReferenceIssues
        )
    }

    private nonisolated static func directDirectories(at rootURL: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
    }

    private nonisolated static func validateSQLite(at url: URL) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close_v2(database) }
            throw LibraryStorageValidationError.sqliteIntegrityFailed(url.lastPathComponent)
        }
        defer { sqlite3_close_v2(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LibraryStorageValidationError.sqliteIntegrityFailed(url.lastPathComponent)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0),
              String(cString: raw).lowercased() == "ok" else {
            throw LibraryStorageValidationError.sqliteIntegrityFailed(url.lastPathComponent)
        }
    }
}

private nonisolated extension MusicLibraryMode {
    var storageKind: LocalTrackStorageKind {
        switch self {
        case .managed: return .managed
        case .referenced: return .referenced
        }
    }
}
