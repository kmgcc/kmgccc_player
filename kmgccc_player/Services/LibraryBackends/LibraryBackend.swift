//
//  LibraryBackend.swift
//  kmgccc_player
//

import Foundation

nonisolated enum LibraryBackendError: Error, Equatable, LocalizedError {
    case modeMismatch(expected: MusicLibraryMode, actual: LocalTrackStorageKind)
    case unsupportedReferencedNCM
    case bookmarkCreationFailed
    case sourceOutsideAuthorization

    var errorDescription: String? {
        switch self {
        case .modeMismatch(let expected, let actual):
            return "Import placement \(actual.rawValue) is not valid for a \(expected.rawValue) library."
        case .unsupportedReferencedNCM:
            return "Referenced NCM conversion is not available yet."
        case .bookmarkCreationFailed:
            return "The selected file permission could not be saved."
        case .sourceOutsideAuthorization:
            return "The selected file resolves outside its authorized source."
        }
    }
}

@MainActor
protocol LibraryStorageBackend: AnyObject {
    var mode: MusicLibraryMode { get }
    var lastPreparedInputPlan: ImportInputPlan? { get }
    func prepareInputs(_ selectedURLs: [URL]) async -> ImportInputPlan
    func makePlacement(
        for file: ImportDiscoveredFile,
        trackID: UUID,
        stagingDirectoryURL: URL
    ) async throws -> ImportPlacement
    func validate(_ placement: ImportPlacement) throws
    /// Creates or reuses explicit source-to-playlist edges for an import
    /// target. Managed libraries intentionally return an empty map because
    /// their imported files have no external source lifecycle.
    func bindSourcesToPlaylist(
        _ sourceIDs: Set<UUID>,
        playlistID: UUID
    ) async throws -> [UUID: UUID]
    /// Persists source/manual membership provenance separately from the
    /// ordered playlist sidecar.
    func recordSourceMemberships(_ tracks: [Track], playlistID: UUID) async
    /// Atomically establishes source bindings and source-contribution records
    /// for the final playlist-import commit. Implementations must roll back
    /// bindings created by this call when contribution persistence fails.
    func commitPlaylistImportSourceEffects(
        tracks: [Track],
        sourceIDs: Set<UUID>,
        playlistID: UUID
    ) async throws
    func recordManualPlaylistAddition(playlistID: UUID, trackIDs: [UUID]) async
    func recordManualPlaylistRemoval(playlistID: UUID, trackIDs: [UUID]) async
    /// Removes single-file sources created during the last `prepareInputs`
    /// batch whose file did not produce an imported or reused track (for
    /// example corrupt audio). Sources referenced by an imported track's
    /// memberships are kept — NCM conversion outputs carry the source
    /// membership of their `.ncm` input even though the imported file is
    /// the converted product. Referenced backends override; the default is
    /// a no-op.
    func pruneUnimportedFileSources(importedURLs: Set<String>, importedSourceIDs: Set<UUID>) async
    func finishImportBatch()
    func close() async
}

extension LibraryStorageBackend {
    func bindSourcesToPlaylist(
        _ sourceIDs: Set<UUID>,
        playlistID _: UUID
    ) async throws -> [UUID: UUID] { [:] }

    func recordSourceMemberships(_ tracks: [Track], playlistID: UUID) async {}
    func commitPlaylistImportSourceEffects(
        tracks _: [Track],
        sourceIDs _: Set<UUID>,
        playlistID _: UUID
    ) async throws {}
    func recordManualPlaylistAddition(playlistID: UUID, trackIDs: [UUID]) async {}
    func recordManualPlaylistRemoval(playlistID: UUID, trackIDs: [UUID]) async {}

    func pruneUnimportedFileSources(importedURLs _: Set<String>, importedSourceIDs _: Set<UUID>) async {}
}

@MainActor
enum LibraryStorageBackendFactory {
    static func make(
        context: LibraryContext,
        sourceStore: ReferencedSourceStore? = nil,
        sourceScope: ReferencedSourceScope? = nil,
        playlistMembershipStore: ReferencedPlaylistMembershipStore? = nil,
        requiresSecurityScope: Bool = false
    ) throws -> any LibraryStorageBackend {
        switch context.mode {
        case .managed:
            return ManagedLocalBackend(paths: context.paths)
        case .referenced:
            guard let sourceStore, let sourceScope else {
                throw LibrarySessionFactoryError.missingReferencedSourceServices
            }
            return ReferencedLocalBackend(
                paths: context.paths,
                sourceStore: sourceStore,
                sourceScope: sourceScope,
                playlistMembershipStore: playlistMembershipStore,
                requiresSecurityScope: requiresSecurityScope
            )
        }
    }
}
