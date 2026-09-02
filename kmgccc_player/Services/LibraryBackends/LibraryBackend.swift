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
    /// Atomically establishes source bindings and source-contribution records
    /// for the final playlist-import commit. Implementations must roll back
    /// bindings created by this call when contribution persistence fails.
    func commitPlaylistImportSourceEffects(
        tracks: [Track],
        sourceIDs: Set<UUID>,
        playlistID: UUID,
        commitPlaylist: @MainActor () async throws -> Void
    ) async throws
    /// Persists source descriptors created by the current input plan. Input
    /// planning remains read-only; this is the first durable source write and
    /// runs inside the same short mutation as the playlist commit.
    func commitPreparedSources() async throws
    /// Compensates source descriptors committed by the current import when a
    /// later playlist or membership step fails. Existing sources are untouched.
    func rollbackPreparedSources() async
    func commitManualPlaylistAddition(
        playlistID: UUID,
        trackIDs: [UUID],
        commitPlaylist: @MainActor () async throws -> Void
    ) async throws
    func commitManualPlaylistRemoval(
        playlistID: UUID,
        trackIDs: [UUID],
        commitPlaylist: @MainActor () async throws -> Void
    ) async throws
    func commitPlaylistDeletion(
        playlistID: UUID,
        commitPlaylist: @MainActor () async throws -> Void
    ) async throws
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

    func commitPlaylistImportSourceEffects(
        tracks _: [Track],
        sourceIDs _: Set<UUID>,
        playlistID _: UUID,
        commitPlaylist: @MainActor () async throws -> Void
    ) async throws { try await commitPlaylist() }
    func commitPreparedSources() async throws {}
    func rollbackPreparedSources() async {}
    func commitManualPlaylistAddition(
        playlistID _: UUID,
        trackIDs _: [UUID],
        commitPlaylist: @MainActor () async throws -> Void
    ) async throws { try await commitPlaylist() }
    func commitManualPlaylistRemoval(
        playlistID _: UUID,
        trackIDs _: [UUID],
        commitPlaylist: @MainActor () async throws -> Void
    ) async throws { try await commitPlaylist() }
    func commitPlaylistDeletion(
        playlistID _: UUID,
        commitPlaylist: @MainActor () async throws -> Void
    ) async throws { try await commitPlaylist() }

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
