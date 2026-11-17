import Foundation

nonisolated struct TrackAuthorityDeletionFailure: Sendable, Equatable {
    let trackID: UUID
    let reason: String
}

nonisolated struct TrackAuthorityDeletionPreparationResult: Sendable, Equatable {
    let approvedTrackIDs: Set<UUID>
    let failures: [TrackAuthorityDeletionFailure]
    var additionalTrackIDs: Set<UUID> = []
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
    private let repository: LibraryRepositoryProtocol?
    private let confirmSharedOriginalDeletion: @MainActor ([Track]) async -> Bool?

    init(
        context: LibraryContext,
        sourceScope: ReferencedSourceScope,
        ignoredItemsStore: IgnoredReferencedItemsStore? = nil,
        ncmRegistry: NCMConversionRegistry? = nil,
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        recycler: any LibraryRecycling = MacOSLibraryRecycler(),
        requiresSecurityScope: Bool = false,
        repository: LibraryRepositoryProtocol? = nil,
        confirmSharedOriginalDeletion: @escaping @MainActor ([Track]) async -> Bool? = { _ in false }
    ) {
        self.context = context
        settingsStore = LibraryScopedSettingsStore(paths: context.paths)
        self.sourceScope = sourceScope
        self.ignoredItemsStore = ignoredItemsStore ?? IgnoredReferencedItemsStore(paths: context.paths)
        self.ncmRegistry = ncmRegistry ?? NCMConversionRegistry(paths: context.paths)
        self.bookmarkResolver = bookmarkResolver
        self.recycler = recycler
        self.requiresSecurityScope = requiresSecurityScope
        self.repository = repository
        self.confirmSharedOriginalDeletion = confirmSharedOriginalDeletion
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
        let libraryTracks = await repository?.fetchTracks(in: nil) ?? tracks
        var consideredMedia = Set<String>()
        var cancelledTrackIDs = Set<UUID>()
        for track in tracks where !approvedTrackIDs.contains(track.id) && !cancelledTrackIDs.contains(track.id) {
            guard track.mediaLocator.storageKind == .referenced else {
                approvedTrackIDs.insert(track.id)
                continue
            }
            do {
                if track.mediaSelection != nil, policy == .recycleSource,
                   let locator = track.mediaLocator.referencedFile {
                    let key = locator.fingerprint.map { String(describing: ReferencedPhysicalIdentityKey($0)) } ?? locator.lastKnownPath
                    if consideredMedia.insert(key).inserted {
                        let identities = Set(locator.locations.compactMap(\.fingerprint).map(ReferencedPhysicalIdentityKey.init))
                        let related = libraryTracks.filter { other in
                            guard let otherLocator = other.mediaLocator.referencedFile else { return false }
                            return otherLocator.locations.contains {
                                $0.fingerprint.map { identities.contains(ReferencedPhysicalIdentityKey($0)) } ?? ($0.lastKnownPath == locator.lastKnownPath)
                            }
                        }
                        let choice = await confirmSharedOriginalDeletion(related)
                        guard let choice else {
                            cancelledTrackIDs.formUnion(related.map(\.id))
                            continue
                        }
                        if choice {
                            cancelledTrackIDs.formUnion(related.map(\.id))
                            let inserted = try LogicalAudioTrackTombstones.add(related.compactMap(\.mediaSelection), paths: context.paths)
                            do {
                                try await prepareReferencedTrackRemoval(track, recycleSource: true, allowSharedRecycling: true)
                            } catch {
                                try LogicalAudioTrackTombstones.remove(inserted, paths: context.paths)
                                throw error
                            }
                            approvedTrackIDs.formUnion(related.map(\.id))
                            continue
                        }
                    }
                }
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
            failures: failures,
            additionalTrackIDs: approvedTrackIDs.subtracting(Set(tracks.map(\.id)))
        )
    }

    private func prepareReferencedTrackRemoval(
        _ track: Track,
        recycleSource: Bool,
        allowSharedRecycling: Bool = false
    ) async throws {
        guard case let .referenced(locator) = track.mediaLocator else { return }
        if let selection = track.mediaSelection, !allowSharedRecycling {
            try LogicalAudioTrackTombstones.add(selection, paths: context.paths)
            return
        }
        var ignoredItems: [IgnoredReferencedItem] = []
        if let fingerprint = locator.fingerprint {
            ignoredItems.append(IgnoredReferencedItem(
                fingerprint: fingerprint,
                lastKnownPath: locator.lastKnownPath,
                reason: .trackRemoval
            ))
        }
        // The movie a song was extracted from must not return through the
        // next source scan. Its own identity is tombstones separately from
        // the extracted audio's.
        if let video = locator.videoSource {
            ignoredItems.append(IgnoredReferencedItem(
                fingerprint: video.fingerprint,
                lastKnownPath: video.path,
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
            // Unplayable tracks (missing file, offline volume, denied
            // permission) have no resolvable source; skip the recycle step
            // (it would throw and refuse deletion) while still writing
            // ignore tombstones above so a leftover file can never be
            // re-scanned back.
            if track.availability.isPlayable, recycleSource || locator.videoSource != nil {
                let resolution = try LocalAudioResourceResolver(
                    paths: context.paths,
                    authorizedSourceRoots: sourceScope.authorizedRoots,
                    bookmarkResolver: bookmarkResolver,
                    requiresSecurityScope: requiresSecurityScope
                ).resolve(track.mediaLocator)
                defer { resolution.lease.release() }
                if recycleSource {
                    try await recycler.recycle(resolution.url)
                } else if VideoMusicImporter.isGeneratedAudio(resolution.url) {
                    // Extracted audio is a derivative the app published beside
                    // the movie. The movie itself is the listener's file and
                    // is never touched.
                    do {
                        try FileManager.default.removeItem(at: resolution.url)
                    } catch {
                        Log.warning(
                            "[ReferencedSource] failed to remove extracted video audio \(resolution.url.lastPathComponent): \(error.localizedDescription)",
                            category: .library
                        )
                    }
                }
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
