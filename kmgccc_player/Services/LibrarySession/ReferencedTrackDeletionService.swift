import Foundation

nonisolated struct TrackAuthorityDeletionFailure: Sendable, Equatable {
    let trackID: UUID
    let reason: String
}

nonisolated struct TrackAuthorityDeletionPreparationResult: Sendable, Equatable {
    let approvedTrackIDs: Set<UUID>
    let failures: [TrackAuthorityDeletionFailure]
}

@MainActor
final class ReferencedTrackDeletionService {
    private let context: LibraryContext
    private let settingsStore: LibraryScopedSettingsStore
    private let sourceScope: ReferencedSourceScope
    private let bookmarkResolver: any BookmarkResolving
    private let recycler: any LibraryRecycling
    private let requiresSecurityScope: Bool

    init(
        context: LibraryContext,
        sourceScope: ReferencedSourceScope,
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        recycler: any LibraryRecycling = MacOSLibraryRecycler(),
        requiresSecurityScope: Bool = false
    ) {
        self.context = context
        settingsStore = LibraryScopedSettingsStore(paths: context.paths)
        self.sourceScope = sourceScope
        self.bookmarkResolver = bookmarkResolver
        self.recycler = recycler
        self.requiresSecurityScope = requiresSecurityScope
    }

    func prepareForAuthorityDeletion(_ tracks: [Track]) async -> TrackAuthorityDeletionPreparationResult {
        let policy: ReferencedTrackDeletePolicy
        do {
            policy = try await settingsStore.load().referencedTrackDeletePolicy
        } catch {
            return TrackAuthorityDeletionPreparationResult(
                approvedTrackIDs: [],
                failures: tracks.map {
                    TrackAuthorityDeletionFailure(trackID: $0.id, reason: "无法读取删除方式")
                }
            )
        }
        guard policy == .recycleSource else {
            return TrackAuthorityDeletionPreparationResult(
                approvedTrackIDs: Set(tracks.map(\.id)),
                failures: []
            )
        }

        var approvedTrackIDs = Set<UUID>()
        var failures: [TrackAuthorityDeletionFailure] = []
        for track in tracks {
            guard track.mediaLocator.storageKind == .referenced else {
                approvedTrackIDs.insert(track.id)
                continue
            }
            do {
                let resolution = try LocalAudioResourceResolver(
                    paths: context.paths,
                    authorizedSourceRoots: sourceScope.authorizedRoots,
                    bookmarkResolver: bookmarkResolver,
                    requiresSecurityScope: requiresSecurityScope
                ).resolve(track.mediaLocator)
                defer { resolution.lease.release() }
                try await recycler.recycle(resolution.url)
                approvedTrackIDs.insert(track.id)
            } catch {
                failures.append(
                    TrackAuthorityDeletionFailure(
                        trackID: track.id,
                        reason: "无法将原文件移到废纸篓"
                    )
                )
            }
        }
        return TrackAuthorityDeletionPreparationResult(
            approvedTrackIDs: approvedTrackIDs,
            failures: failures
        )
    }
}
