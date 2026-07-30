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
    private let ignoredItemsStore: IgnoredReferencedItemsStore
    private let ncmRegistry: NCMConversionRegistry
    private let bookmarkResolver: any BookmarkResolving
    private let recycler: any LibraryRecycling
    private let requiresSecurityScope: Bool

    init(
        context: LibraryContext,
        sourceScope: ReferencedSourceScope,
        ignoredItemsStore: IgnoredReferencedItemsStore? = nil,
        ncmRegistry: NCMConversionRegistry? = nil,
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        recycler: any LibraryRecycling = MacOSLibraryRecycler(),
        requiresSecurityScope: Bool = false
    ) {
        self.context = context
        settingsStore = LibraryScopedSettingsStore(paths: context.paths)
        self.sourceScope = sourceScope
        self.ignoredItemsStore = ignoredItemsStore ?? IgnoredReferencedItemsStore(paths: context.paths)
        self.ncmRegistry = ncmRegistry ?? NCMConversionRegistry(paths: context.paths)
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
        var approvedTrackIDs = Set<UUID>()
        var failures: [TrackAuthorityDeletionFailure] = []
        for track in tracks {
            guard track.mediaLocator.storageKind == .referenced else {
                approvedTrackIDs.insert(track.id)
                continue
            }
            do {
                try await prepareReferencedTrackRemoval(
                    track,
                    recycleSource: policy == .recycleSource
                )
                approvedTrackIDs.insert(track.id)
            } catch {
                failures.append(
                    TrackAuthorityDeletionFailure(
                        trackID: track.id,
                        reason: policy == .recycleSource
                            ? "无法将原文件移到废纸篓"
                            : "无法记录移除项目"
                    )
                )
            }
        }
        return TrackAuthorityDeletionPreparationResult(
            approvedTrackIDs: approvedTrackIDs,
            failures: failures
        )
    }

    private func prepareReferencedTrackRemoval(
        _ track: Track,
        recycleSource: Bool
    ) async throws {
        guard case let .referenced(locator) = track.mediaLocator else { return }
        var ignoredItems: [IgnoredReferencedItem] = []
        if let fingerprint = locator.fingerprint {
            ignoredItems.append(IgnoredReferencedItem(
                fingerprint: fingerprint,
                lastKnownPath: locator.lastKnownPath,
                reason: .trackRemoval
            ))
        }

        let operationID = track.ncmConversionAssociation?.operationID
        if let operationID, let record = try await ncmRegistry.record(operationID: operationID) {
            ignoredItems.append(IgnoredReferencedItem(
                fingerprint: record.sourceFingerprint,
                lastKnownPath: record.sourcePath,
                reason: .ncmSourceRemoval
            ))
            if let outputFingerprint = record.outputFingerprint {
                ignoredItems.append(IgnoredReferencedItem(
                    fingerprint: outputFingerprint,
                    lastKnownPath: record.expectedOutputPath,
                    reason: .ncmOutputRemoval
                ))
            }
        }

        let inserted = try await ignoredItemsStore.add(ignoredItems)
        do {
            if let operationID {
                _ = try await ncmRegistry.markRemoved(operationID: operationID)
            }
            if recycleSource {
                let resolution = try LocalAudioResourceResolver(
                    paths: context.paths,
                    authorizedSourceRoots: sourceScope.authorizedRoots,
                    bookmarkResolver: bookmarkResolver,
                    requiresSecurityScope: requiresSecurityScope
                ).resolve(track.mediaLocator)
                defer { resolution.lease.release() }
                try await recycler.recycle(resolution.url)
            }
        } catch {
            if let operationID {
                try? await ncmRegistry.restoreAfterFailedRemoval(operationID: operationID)
            }
            try? await ignoredItemsStore.remove(matching: inserted)
            throw error
        }
    }
}
