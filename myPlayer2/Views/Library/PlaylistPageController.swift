//
//  PlaylistPageController.swift
//  myPlayer2
//
//  Stable controller for playlist detail page lifecycle, caching, and artwork input.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class PlaylistPageController {
    private struct SortableTrackEntry: Sendable {
        let id: UUID
        let title: String
        let artist: String
        let duration: Double
        let playCount: Int
        let preferenceScore: Double
        let addedAt: Date
        let importedAt: Date?
        let playlistItemAddedAt: Date?
    }

    private struct BuildResult: Sendable {
        let rowRecords: [PlaylistPageRowRecord]
        let queueTrackIDs: [UUID]
        let queueIndexMap: [UUID: Int]
        let displayedTrackCount: Int
        let filteredTrackCount: Int
        let displayedTotalDuration: Double
    }

    private struct HeaderArtworkPayload: Sendable {
        let data: Data?
        let fileURL: URL?
    }

    private enum FadeTiming {
        /// Crossfade duration for header artwork (old layer stays visible during fade)
        static let headerCrossfadeDuration: Double = 0.26
        /// Crossfade duration for halo (slower + delayed for softer appearance)
        static let haloReadyDelayNanoseconds: UInt64 = 70_000_000
        static let haloReadyFadeDuration: Double = 0.54
        static let haloSeedPixelSide: Int = 192
    }

    private(set) var phase: PlaylistPagePhase = .idle
    private(set) var page: PlaylistPageModel?
    private(set) var isSelectionTransitioning = false
    private(set) var areRowSecondaryInteractionsEnabled = false
    private(set) var areRowArtworkLoadsEnabled = true
    private(set) var isRowArtworkPrefetchEnabled = false
    private(set) var isHeaderEffectsEnabled = false

    // MARK: - Header Artwork Crossfade State
    /// Current visible artwork layer (old or placeholder)
    private(set) var headerCurrentArtwork: NSImage?
    /// Incoming artwork layer (new image to crossfade in)
    private(set) var headerIncomingArtwork: NSImage?
    /// Opacity of incoming layer (0 = show current, 1 = show incoming)
    private(set) var headerIncomingOpacity: Double = 0

    // MARK: - Halo Crossfade State (low-resolution seed image)
    private(set) var haloCurrentImage: NSImage?
    private(set) var haloIncomingImage: NSImage?
    private(set) var haloSourceBlendOpacity: Double = 1
    private(set) var haloPresentationOpacity: Double = 0

    var searchText = ""
    var listScrollPositionID: UUID?
    var isMultiselectMode = false
    var selectedTrackIDs: Set<UUID> = []

    let haloState = HeaderHaloState()

    private var libraryVM: LibraryViewModel?
    private var playerVM: PlayerViewModel?
    private var uiState: UIStateViewModel?

    private var rebuildTask: Task<Void, Never>?
    private var snapshotUpdateTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var headerResolveTask: Task<Void, Never>?
    private var headerUpgradeTask: Task<Void, Never>?
    private var headerFadeTask: Task<Void, Never>?
    private var haloFadeTask: Task<Void, Never>?
    private var phaseTask: Task<Void, Never>?
    private var activeLoadToken = UUID()
    private var phaseToken = UUID()
    private var headerResolveToken = UUID()
    private var lastQueueTrackIDs: [UUID] = []
    private var lastPrefetchBucket: Int?
    private var currentArtworkPresentationIdentity: String?
    private var didFadeHeaderIdentity: String?
    private var didFadeHaloIdentity: String?
    @ObservationIgnored
    private var lastPlaybackTrackChangeUptime: TimeInterval = 0
    @ObservationIgnored
    private var headerHeavyWorkBaselineUptime: TimeInterval = 0
    @ObservationIgnored
    private var hasObservedPlaybackTrackChangeSinceBaseline = false

    func bind(
        libraryVM: LibraryViewModel,
        playerVM: PlayerViewModel,
        uiState: UIStateViewModel
    ) {
        self.libraryVM = libraryVM
        self.playerVM = playerVM
        self.uiState = uiState
    }

    func appear() {
        guard let libraryVM else { return }
        haloState.beginSession(selectionIdentity: selectionIdentity(for: libraryVM.currentSelection))
        resetHeaderHeavyWorkDeferralBaseline()
        activateFirstPaintPhases(for: libraryVM.currentSelection)
        scheduleRebuild(reason: "appear", restoreScroll: true)
    }

    func disappear() {
        cancelAllTasks(clearPage: true)
        phase = .idle
        page = nil
        lastQueueTrackIDs = []
        resetArtworkPresentation(force: true, identity: nil)
        resetHeaderHeavyWorkDeferralBaseline()
        haloState.clear()
    }

    func handleSelectionChange(_ selection: LibrarySelection) {
        resetHeaderHeavyWorkDeferralBaseline()
        beginSelectionTransition(to: selection)
        scheduleRebuild(reason: "selection", restoreScroll: true)
    }

    func handleSearchChange() {
        scheduleRebuild(reason: "search", debounceNanoseconds: 150_000_000)
    }

    func handleSortChange(reason: String) {
        scheduleRebuild(reason: reason)
    }

    func handleLibraryRefresh(reason: String, restoreScroll: Bool) {
        scheduleRebuild(reason: reason, restoreScroll: restoreScroll)
    }

    func updateScrollPosition(_ trackID: UUID?) {
        listScrollPositionID = trackID
        scheduleSnapshotUpdate()
    }

    func refreshHeaderArtwork() {
        guard page?.header != nil else { return }
        LyricsRuntimeProfile.increment("header.refreshHeaderArtwork")
        rebuildCurrentHeaderModel(forceResetArtworkPresentation: true)
        loadHeaderArtwork()
    }

    func notePlaybackTrackDidChange() {
        lastPlaybackTrackChangeUptime = ProcessInfo.processInfo.systemUptime
        hasObservedPlaybackTrackChangeSinceBaseline = true
    }

    func clearMultiselectState() {
        uiState?.lyricsPanelSuppressedByModal = false
        isMultiselectMode = false
        selectedTrackIDs.removeAll()
    }

    func releaseSelectionStateForTeardown() {
        isMultiselectMode = false
        selectedTrackIDs.removeAll()
        listScrollPositionID = nil
        lastPrefetchBucket = nil
    }

    func updateHeaderArtworkBounds(_ bounds: CGRect, selectionIdentity: String) {
        LyricsRuntimeProfile.increment("header.artworkBoundsUpdate.called")
        guard haloState.selectionIdentity == selectionIdentity else { return }
        if haloState.updateAnchor(bounds: bounds) {
            LyricsRuntimeProfile.increment("header.artworkBoundsUpdate.changed")
        } else {
            LyricsRuntimeProfile.increment("header.artworkBoundsUpdate.same")
        }
    }

    func updateHaloScroll(offset: CGFloat) {
        LyricsRuntimeProfile.increment("header.haloScrollUpdate.called")
        if haloState.updateScroll(offset: offset) {
            LyricsRuntimeProfile.increment("header.haloScrollUpdate.changed")
        } else {
            LyricsRuntimeProfile.increment("header.haloScrollUpdate.same")
        }
    }

    private var lastPrefetchTime: Date = .distantPast
    private let prefetchDebounceInterval: TimeInterval = 0.08

    func prefetchAroundTrackID(_ trackID: UUID) {
        guard isRowArtworkPrefetchEnabled else { return }
        guard let page else { return }
        guard let startIndex = page.rows.firstIndex(where: { $0.id == trackID }) else { return }
        
        let now = Date()
        guard now.timeIntervalSince(lastPrefetchTime) >= prefetchDebounceInterval else { return }
        lastPrefetchTime = now
        
        let bucket = startIndex / 4
        guard bucket != lastPrefetchBucket else { return }
        lastPrefetchBucket = bucket

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        
        let windowSize = 8
        let start = max(0, startIndex - windowSize)
        let end = min(page.rows.count, startIndex + windowSize + 1)
        guard start < end else { return }

        let requests = page.rows[start..<end].map {
            PlaylistArtworkPipeline.rowHighRequest(
                trackID: $0.id,
                artworkData: $0.artworkData,
                logicalSize: Constants.Layout.artworkSmallSize,
                scale: scale
            )
        }
        prefetchTask?.cancel()
        prefetchTask = PlaylistArtworkPipeline.shared.prefetch(Array(requests))
    }

    func applyTargetedTrackRefresh(trackID _: UUID) {
        scheduleRebuild(reason: "track-update")
    }

    func latestTrackFromLibrary(trackID: UUID) -> Track? {
        guard let libraryVM else { return nil }
        if let track = libraryVM.allTracks.first(where: { $0.id == trackID }) {
            return track
        }
        return page?.queueTracks.first(where: { $0.id == trackID })
    }

    func queueStartIndex(for trackID: UUID) -> Int {
        page?.queueIndexMap[trackID] ?? 0
    }

    private func beginSelectionTransition(to selection: LibrarySelection) {
        isSelectionTransitioning = true
        phase = .transitioning
        beginTeardown()
        releaseSelectionStateForTeardown()
        page = nil
        resetArtworkPresentation(force: true, identity: nil)

        let selectionIdentity = selectionIdentity(for: selection)
        haloState.beginSession(selectionIdentity: selectionIdentity)
        activateFirstPaintPhases(for: selection)
    }

    private func beginTeardown() {
        phaseTask?.cancel()
        headerResolveTask?.cancel()
        headerUpgradeTask?.cancel()
        headerFadeTask?.cancel()
        haloFadeTask?.cancel()
        prefetchTask?.cancel()
        snapshotUpdateTask?.cancel()
        rebuildTask?.cancel()
        phaseToken = UUID()
        headerResolveToken = UUID()
        areRowSecondaryInteractionsEnabled = false
        areRowArtworkLoadsEnabled = false
        isRowArtworkPrefetchEnabled = false
        isHeaderEffectsEnabled = false
        headerIncomingOpacity = 0
        haloSourceBlendOpacity = 1
        haloPresentationOpacity = 0
    }

    private func activateFirstPaintPhases(for selection: LibrarySelection) {
        phaseTask?.cancel()
        areRowSecondaryInteractionsEnabled = false
        areRowArtworkLoadsEnabled = true
        isRowArtworkPrefetchEnabled = false
        isHeaderEffectsEnabled = selection == .allSongs

        let token = UUID()
        phaseToken = token
        phaseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 130_000_000)
            guard !Task.isCancelled, self.phaseToken == token else { return }
            self.areRowSecondaryInteractionsEnabled = true
            self.isRowArtworkPrefetchEnabled = true

            guard selection != .allSongs else { return }
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, self.phaseToken == token else { return }
            self.isHeaderEffectsEnabled = true
            LyricsRuntimeProfile.increment("header.effectsEnabled.true")
        }
    }

    private func cancelAllTasks(clearPage: Bool) {
        beginTeardown()
        if clearPage {
            page = nil
        }
    }

    private func scheduleSnapshotUpdate() {
        snapshotUpdateTask?.cancel()
        snapshotUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self.updateLibrarySnapshot()
        }
    }

    private func scheduleRebuild(
        reason: String,
        debounceNanoseconds: UInt64 = 0,
        restoreScroll: Bool = false
    ) {
        rebuildTask?.cancel()
        let token = UUID()
        activeLoadToken = token
        rebuildTask = Task { @MainActor in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled else { return }
            phase = .firstPaint
            await performRebuild(reason: reason, restoreScroll: restoreScroll, token: token)
        }
    }

    private func performRebuild(
        reason: String,
        restoreScroll: Bool,
        token: UUID
    ) async {
        guard let libraryVM else { return }

        let rebuildStart = ProcessInfo.processInfo.systemUptime
        let selection = libraryVM.currentSelection
        let selectionIdentity = selectionIdentity(for: selection)
        let displayedTracks = currentDisplayedTracks(selection: selection, libraryVM: libraryVM)
        let displayedTrackByID = Dictionary(uniqueKeysWithValues: displayedTracks.map { ($0.id, $0) })
        let trimmedSearch = normalizedSearch(searchText)
        let sourceFingerprint = pageSourceFingerprint(
            for: displayedTracks,
            libraryVM: libraryVM
        )

        let modelKey = await PlaylistPageModelCacheService.shared.cacheKey(
            selectionIdentity: selectionIdentity,
            sourceFingerprint: sourceFingerprint,
            searchText: trimmedSearch,
            sortKeyRawValue: libraryVM.trackSortKey.rawValue,
            sortOrderRawValue: libraryVM.trackSortOrder.rawValue
        )

        if let cached = await PlaylistPageModelCacheService.shared.model(for: modelKey),
           let cachedPage = hydratedPageModel(
                selection: selection,
                selectionIdentity: selectionIdentity,
                sourceFingerprint: sourceFingerprint,
                displayedTracks: displayedTracks,
                displayedTrackByID: displayedTrackByID,
                cacheEntry: cached
           )
        {
            guard activeLoadToken == token, !Task.isCancelled else { return }
            applyPageModel(cachedPage, restoreScroll: restoreScroll)
            PlaylistPerfDiagnostics.markListRebuild(
                reason: "\(reason)-cache-hit",
                trackCount: cachedPage.rows.count,
                durationMs: (ProcessInfo.processInfo.systemUptime - rebuildStart) * 1000
            )
            return
        }

        let playlistItemAddedAtMap: [UUID: Date]? = {
            guard let playlistID = libraryVM.selectedPlaylistId else { return nil }
            return libraryVM.playlistItemAddedAtMap[playlistID]
        }()

        let sortableEntries = displayedTracks.map {
            SortableTrackEntry(
                id: $0.id,
                title: $0.title,
                artist: $0.artist,
                duration: $0.duration,
                playCount: Self.normalizedPlayCount(for: $0),
                preferenceScore: Self.normalizedPreferenceScore(for: $0),
                addedAt: $0.addedAt,
                importedAt: $0.importedAt,
                playlistItemAddedAt: playlistItemAddedAtMap?[$0.id]
            )
        }

        let buildResult = await Self.buildPageResult(
            displayedTracks: displayedTracks,
            entries: sortableEntries,
            searchText: trimmedSearch,
            sortKey: libraryVM.trackSortKey,
            sortOrder: libraryVM.trackSortOrder
        )

        guard !Task.isCancelled, activeLoadToken == token else { return }

        let queueTracks = buildResult.queueTrackIDs.compactMap { displayedTrackByID[$0] }
        let rows: [PlaylistPageRowModel] = buildResult.rowRecords.compactMap { record -> PlaylistPageRowModel? in
            guard let track = displayedTrackByID[record.id] else { return nil }
            return PlaylistPageRowModel(record: record, artworkData: track.artworkData)
        }
        guard queueTracks.count == buildResult.queueTrackIDs.count,
              rows.count == buildResult.rowRecords.count
        else {
            return
        }

        let pageModel = PlaylistPageModel(
            selection: selection,
            selectionIdentity: selectionIdentity,
            sourceFingerprint: sourceFingerprint,
            displayedTrackCount: buildResult.displayedTrackCount,
            filteredTrackCount: buildResult.filteredTrackCount,
            displayedTotalDuration: buildResult.displayedTotalDuration,
            rows: rows,
            queueTracks: queueTracks,
            queueIndexMap: buildResult.queueIndexMap,
            header: buildHeaderModel(
                selection: selection,
                libraryVM: libraryVM,
                displayedTracks: displayedTracks,
                displayedTotalDuration: buildResult.displayedTotalDuration
            )
        )

        await PlaylistPageModelCacheService.shared.store(
            PlaylistPageModelCacheEntry(
                key: modelKey,
                selectionIdentity: selectionIdentity,
                sourceFingerprint: sourceFingerprint,
                searchText: trimmedSearch,
                sortKeyRawValue: libraryVM.trackSortKey.rawValue,
                sortOrderRawValue: libraryVM.trackSortOrder.rawValue,
                displayedTrackIDs: displayedTracks.map(\.id),
                rowRecords: buildResult.rowRecords,
                queueTrackIDs: buildResult.queueTrackIDs,
                queueIndexMap: buildResult.queueIndexMap,
                displayedTrackCount: buildResult.displayedTrackCount,
                filteredTrackCount: buildResult.filteredTrackCount,
                displayedTotalDuration: buildResult.displayedTotalDuration,
                cachedAt: Date()
            )
        )

        guard !Task.isCancelled, activeLoadToken == token else { return }
        applyPageModel(pageModel, restoreScroll: restoreScroll)

        PlaylistPerfDiagnostics.markListRebuild(
            reason: reason,
            trackCount: pageModel.rows.count,
            durationMs: (ProcessInfo.processInfo.systemUptime - rebuildStart) * 1000
        )
    }

    private func applyPageModel(_ pageModel: PlaylistPageModel, restoreScroll: Bool) {
        resetArtworkPresentation(force: false, identity: pageModel.header?.artworkIdentity)
        page = pageModel
        LyricsRuntimeProfile.setMetadata("page.rows.count", value: "\(pageModel.rows.count)")
        LyricsRuntimeProfile.setMetadata(
            "page.header.present",
            value: pageModel.header == nil ? "false" : "true"
        )
        LyricsRuntimeProfile.setMetadata("page.queue.count", value: "\(pageModel.queueTracks.count)")
        selectedTrackIDs.formIntersection(Set(pageModel.rows.map(\.id)))
        lastPrefetchBucket = nil
        isSelectionTransitioning = false
        phase = .ready

        if restoreScroll {
            restoreScrollIfNeeded()
        } else if listScrollPositionID != nil, !(pageModel.rows.contains { $0.id == listScrollPositionID }) {
            listScrollPositionID = nil
        }

        updateLibrarySnapshot()
        syncPlayerQueueIfNeeded(
            with: pageModel.queueTracks,
            selectionIdentity: pageModel.selectionIdentity
        )
        loadHeaderArtwork()
    }

    private func rebuildCurrentHeaderModel(forceResetArtworkPresentation: Bool) {
        guard let currentPage = page, let libraryVM else { return }

        let displayedTracks = currentDisplayedTracks(
            selection: currentPage.selection,
            libraryVM: libraryVM
        )
        let rebuiltHeader = buildHeaderModel(
            selection: currentPage.selection,
            libraryVM: libraryVM,
            displayedTracks: displayedTracks,
            displayedTotalDuration: currentPage.displayedTotalDuration
        )

        var updatedPage = currentPage
        updatedPage.header = rebuiltHeader
        page = updatedPage

        resetArtworkPresentation(
            force: forceResetArtworkPresentation,
            identity: rebuiltHeader?.artworkIdentity
        )
    }

    private func loadHeaderArtwork() {
        guard let page, let header = page.header else {
            resetArtworkPresentation(force: false, identity: nil)
            return
        }

        LyricsRuntimeProfile.increment("header.loadHeaderArtwork")
        LyricsRuntimeProfile.setMetadata("header.selectionIdentity", value: page.selectionIdentity)
        LyricsRuntimeProfile.setMetadata("header.artworkIdentity", value: header.artworkIdentity)

        headerResolveTask?.cancel()
        headerUpgradeTask?.cancel()
        let request = header.config.artworkRequest
        let selectionIdentity = page.selectionIdentity
        let loadToken = UUID()
        headerResolveToken = loadToken
        resetHeaderHeavyWorkDeferralBaseline()

        headerResolveTask = Task { @MainActor in
            let immediateStart = ProcessInfo.processInfo.systemUptime
            let immediate = DetailHeaderArtworkResolver.shared.resolveImmediately(for: request)
            LyricsRuntimeProfile.increment("header.resolveImmediate.count")
            LyricsRuntimeProfile.addDuration(
                "header.resolveImmediate",
                ms: (ProcessInfo.processInfo.systemUptime - immediateStart) * 1000
            )
            self.applyResolvedHeaderArtwork(
                immediate,
                artworkIdentity: header.artworkIdentity,
                selectionIdentity: selectionIdentity,
                resolveToken: loadToken
            )

            let deferredStart = ProcessInfo.processInfo.systemUptime
            let resolved = await DetailHeaderArtworkResolver.shared.resolveDeferredArtwork(for: request)
            LyricsRuntimeProfile.increment("header.resolveDeferred.count")
            LyricsRuntimeProfile.addDuration(
                "header.resolveDeferred",
                ms: (ProcessInfo.processInfo.systemUptime - deferredStart) * 1000
            )
            guard !Task.isCancelled, self.headerResolveToken == loadToken else { return }

            let finalResolved = resolved ?? immediate
            self.applyResolvedHeaderArtwork(
                finalResolved,
                artworkIdentity: header.artworkIdentity,
                selectionIdentity: selectionIdentity,
                resolveToken: loadToken
            )
        }
    }

    private func applyResolvedHeaderArtwork(
        _ resolved: ResolvedHeaderArtwork?,
        artworkIdentity: String,
        selectionIdentity: String,
        resolveToken: UUID
    ) {
        LyricsRuntimeProfile.increment("header.applyResolvedArtwork")
        guard var currentPage = page, currentPage.selectionIdentity == selectionIdentity else { return }
        guard var currentHeader = currentPage.header else { return }

        // Immediate stage: publish what we have right away.
        if let image = resolved?.image {
            LyricsRuntimeProfile.increment("header.applyResolvedArtwork.image")
            currentHeader.artwork = image
            currentPage.header = currentHeader
            page = currentPage
            publishHeaderImage(image, identity: artworkIdentity, resolveToken: resolveToken)
            let haloSeedStart = ProcessInfo.processInfo.systemUptime
            let haloSeed = immediateHaloSeed(from: image)
            LyricsRuntimeProfile.increment("header.immediateHaloSeed.count")
            LyricsRuntimeProfile.addDuration(
                "header.immediateHaloSeed",
                ms: (ProcessInfo.processInfo.systemUptime - haloSeedStart) * 1000
            )
            publishHaloImage(
                haloSeed,
                identity: artworkIdentity,
                resolveToken: resolveToken
            )
        }

        let payload = headerArtworkPayload(
            request: currentHeader.config.artworkRequest,
            resolved: resolved
        )
        guard payload.data != nil || payload.fileURL != nil else { return }

        headerUpgradeTask?.cancel()
        let shouldDeferHeavyUpgrade = shouldDeferHeaderHeavyWork
        headerUpgradeTask = Task { @MainActor in
            if shouldDeferHeavyUpgrade {
                await self.waitForHeaderHeavyWorkQuietWindow(resolveToken: resolveToken)
                guard !Task.isCancelled else { return }
                guard self.headerResolveToken == resolveToken else { return }
            }
            let upgradeStart = ProcessInfo.processInfo.systemUptime
            let headerRequest = PlaylistArtworkPipeline.headerRequest(
                artworkIdentity: artworkIdentity,
                artworkData: payload.data,
                fileURL: payload.fileURL
            )
            let haloSeedRequest = PlaylistArtworkPipeline.haloSeedRequest(
                artworkIdentity: artworkIdentity,
                artworkData: payload.data,
                fileURL: payload.fileURL,
                pixelSide: FadeTiming.haloSeedPixelSide
            )

            async let upgradedHeader = PlaylistArtworkPipeline.shared.load(headerRequest)
            async let upgradedHaloSeed = PlaylistArtworkPipeline.shared.load(haloSeedRequest)

            let (headerImage, haloSeedImage) = await (upgradedHeader, upgradedHaloSeed)
            LyricsRuntimeProfile.increment("header.pipelineUpgrade.count")
            LyricsRuntimeProfile.addDuration(
                "header.pipelineUpgrade",
                ms: (ProcessInfo.processInfo.systemUptime - upgradeStart) * 1000
            )
            guard !Task.isCancelled else { return }
            guard self.headerResolveToken == resolveToken else { return }
            guard var currentPage = self.page, currentPage.selectionIdentity == selectionIdentity else { return }
            guard var currentHeader = currentPage.header else { return }

            if let headerImage {
                currentHeader.artwork = headerImage
            }
            currentPage.header = currentHeader
            self.page = currentPage

            if let headerImage {
                self.publishHeaderImage(
                    headerImage,
                    identity: artworkIdentity,
                    resolveToken: resolveToken
                )
            }
            self.publishHaloImage(
                haloSeedImage ?? headerImage,
                identity: artworkIdentity,
                resolveToken: resolveToken
            )
        }
    }

    private var shouldDeferHeaderHeavyWork: Bool {
        guard let uiState else { return false }
        return uiState.lyricsVisible && !uiState.lyricsPanelSuppressedByModal
    }

    private func waitForHeaderHeavyWorkQuietWindow(resolveToken: UUID) async {
        let quietInterval: TimeInterval = 0.35
        let baseline = headerHeavyWorkBaselineUptime > 0
            ? headerHeavyWorkBaselineUptime
            : ProcessInfo.processInfo.systemUptime
        let deadline = baseline + 3.0

        while ProcessInfo.processInfo.systemUptime < deadline {
            guard !Task.isCancelled else { return }
            guard headerResolveToken == resolveToken else { return }

            if !hasObservedPlaybackTrackChangeSinceBaseline {
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }

            let idleTime = ProcessInfo.processInfo.systemUptime - lastPlaybackTrackChangeUptime
            if idleTime >= quietInterval {
                return
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func resetHeaderHeavyWorkDeferralBaseline() {
        headerHeavyWorkBaselineUptime = ProcessInfo.processInfo.systemUptime
        hasObservedPlaybackTrackChangeSinceBaseline = false
        lastPlaybackTrackChangeUptime = 0
    }

    private func resetArtworkPresentation(force: Bool, identity: String?) {
        guard force || currentArtworkPresentationIdentity != identity else { return }
        LyricsRuntimeProfile.increment("header.resetArtworkPresentation")
        currentArtworkPresentationIdentity = identity
        didFadeHeaderIdentity = nil
        didFadeHaloIdentity = nil
        headerFadeTask?.cancel()
        haloFadeTask?.cancel()
        headerCurrentArtwork = nil
        headerIncomingArtwork = nil
        headerIncomingOpacity = 0
        haloCurrentImage = nil
        haloIncomingImage = nil
        haloSourceBlendOpacity = 1
        haloPresentationOpacity = 0
    }

    private func publishHeaderImage(_ image: NSImage, identity: String, resolveToken: UUID) {
        guard currentArtworkPresentationIdentity == identity else { return }
        LyricsRuntimeProfile.increment("header.publishHeaderImage")
        if didFadeHeaderIdentity == identity {
            if headerIncomingArtwork != nil {
                headerIncomingArtwork = image
            } else {
                headerCurrentArtwork = image
            }
            return
        }
        triggerHeaderCrossfadeIfNeeded(identity: identity, image: image, resolveToken: resolveToken)
    }

    private func publishHaloImage(_ image: NSImage?, identity: String, resolveToken: UUID) {
        guard let image else { return }
        guard currentArtworkPresentationIdentity == identity else { return }
        LyricsRuntimeProfile.increment("header.publishHaloImage")
        if didFadeHaloIdentity == identity {
            if haloIncomingImage != nil {
                haloIncomingImage = image
            } else {
                haloCurrentImage = image
            }
            return
        }
        triggerHaloCrossfadeIfNeeded(identity: identity, image: image, resolveToken: resolveToken)
    }

    private func triggerHeaderCrossfadeIfNeeded(identity: String, image: NSImage, resolveToken: UUID) {
        guard currentArtworkPresentationIdentity == identity else { return }
        didFadeHeaderIdentity = identity
        headerFadeTask?.cancel()
        LyricsRuntimeProfile.increment("header.crossfade.trigger")

        headerIncomingArtwork = image
        headerIncomingOpacity = 0

        headerFadeTask = Task { @MainActor in
            let fadeStart = ProcessInfo.processInfo.systemUptime
            await Task.yield()
            guard self.headerResolveToken == resolveToken else { return }
            guard !Task.isCancelled else { return }
            guard self.currentArtworkPresentationIdentity == identity else { return }

            LyricsRuntimeProfile.increment("header.crossfade.animationStart")
            withAnimation(.easeInOut(duration: FadeTiming.headerCrossfadeDuration)) {
                self.headerIncomingOpacity = 1
            }

            try? await Task.sleep(nanoseconds: UInt64(FadeTiming.headerCrossfadeDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard self.currentArtworkPresentationIdentity == identity else { return }

            self.headerCurrentArtwork = image
            self.headerIncomingArtwork = nil
            self.headerIncomingOpacity = 0
            LyricsRuntimeProfile.increment("header.crossfade.complete")
            LyricsRuntimeProfile.addDuration(
                "header.crossfade",
                ms: (ProcessInfo.processInfo.systemUptime - fadeStart) * 1000
            )
        }
    }

    private func triggerHaloCrossfadeIfNeeded(identity: String, image: NSImage?, resolveToken: UUID) {
        guard let image else { return }
        guard currentArtworkPresentationIdentity == identity else { return }
        didFadeHaloIdentity = identity
        haloFadeTask?.cancel()
        LyricsRuntimeProfile.increment("header.halo.trigger")

        haloIncomingImage = image
        haloSourceBlendOpacity = 1
        haloPresentationOpacity = 0

        haloFadeTask = Task { @MainActor in
            let fadeStart = ProcessInfo.processInfo.systemUptime
            while !self.isHeaderEffectsEnabled {
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled else { return }
                guard self.currentArtworkPresentationIdentity == identity else { return }
            }
            guard self.headerResolveToken == resolveToken else { return }
            try? await Task.sleep(nanoseconds: FadeTiming.haloReadyDelayNanoseconds)
            guard !Task.isCancelled else { return }
            guard self.currentArtworkPresentationIdentity == identity else { return }
            await Task.yield()

            LyricsRuntimeProfile.increment("header.halo.animationStart")
            withAnimation(.easeInOut(duration: FadeTiming.haloReadyFadeDuration)) {
                self.haloPresentationOpacity = 1
            }

            try? await Task.sleep(nanoseconds: UInt64(FadeTiming.haloReadyFadeDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard self.currentArtworkPresentationIdentity == identity else { return }

            self.haloCurrentImage = self.haloIncomingImage ?? image
            self.haloIncomingImage = nil
            self.haloSourceBlendOpacity = 1
            self.haloPresentationOpacity = 1
            LyricsRuntimeProfile.increment("header.halo.complete")
            LyricsRuntimeProfile.addDuration(
                "header.halo",
                ms: (ProcessInfo.processInfo.systemUptime - fadeStart) * 1000
            )
        }
    }

    private func immediateHaloSeed(from image: NSImage) -> NSImage? {
        ArtworkLoader.headerPreviewImage(
            data: image.tiffRepresentation,
            maxPixelSize: FadeTiming.haloSeedPixelSide
        )
    }

    private func headerArtworkPayload(
        request: DetailHeaderArtworkRequest,
        resolved: ResolvedHeaderArtwork?
    ) -> HeaderArtworkPayload {
        switch request {
        case .playlist:
            return HeaderArtworkPayload(
                data: resolved?.image?.tiffRepresentation,
                fileURL: resolved?.fileURL
            )
        case .artist(_, let entry):
            return HeaderArtworkPayload(
                data: entry.artworkData ?? resolved?.image?.tiffRepresentation,
                fileURL: resolved?.fileURL
            )
        case .album(_, let entry, let fallbackImage):
            return HeaderArtworkPayload(
                data: entry.artworkData ?? fallbackImage?.tiffRepresentation ?? resolved?.image?.tiffRepresentation,
                fileURL: resolved?.fileURL
            )
        }
    }

    private func hydratedPageModel(
        selection: LibrarySelection,
        selectionIdentity: String,
        sourceFingerprint: String,
        displayedTracks: [Track],
        displayedTrackByID: [UUID: Track],
        cacheEntry: PlaylistPageModelCacheEntry
    ) -> PlaylistPageModel? {
        let rows: [PlaylistPageRowModel] = cacheEntry.rowRecords.compactMap {
            guard let track = displayedTrackByID[$0.id] else { return nil }
            return PlaylistPageRowModel(record: $0, artworkData: track.artworkData)
        }
        let queueTracks = cacheEntry.queueTrackIDs.compactMap { displayedTrackByID[$0] }
        guard rows.count == cacheEntry.rowRecords.count,
              queueTracks.count == cacheEntry.queueTrackIDs.count
        else {
            return nil
        }

        return PlaylistPageModel(
            selection: selection,
            selectionIdentity: selectionIdentity,
            sourceFingerprint: sourceFingerprint,
            displayedTrackCount: cacheEntry.displayedTrackCount,
            filteredTrackCount: cacheEntry.filteredTrackCount,
            displayedTotalDuration: cacheEntry.displayedTotalDuration,
            rows: rows,
            queueTracks: queueTracks,
            queueIndexMap: cacheEntry.queueIndexMap,
            header: buildHeaderModel(
                selection: selection,
                libraryVM: libraryVM,
                displayedTracks: displayedTracks,
                displayedTotalDuration: cacheEntry.displayedTotalDuration
            )
        )
    }

    private func buildHeaderModel(
        selection: LibrarySelection,
        libraryVM: LibraryViewModel?,
        displayedTracks: [Track],
        displayedTotalDuration: Double
    ) -> PlaylistPageHeaderModel? {
        guard let libraryVM else { return nil }

        let config: DetailHeaderConfig?
        switch selection {
        case .allSongs:
            config = nil
        case .playlist(let id):
            guard let playlist = libraryVM.playlists.first(where: { $0.id == id }) else { return nil }
            let artworkRevision = LocalLibraryService.shared.playlistArtworkRevision(playlistID: playlist.id)
            config = .playlist(
                playlist,
                entry: PlaylistHeaderData(
                    description: playlist.userDescription,
                    tracks: displayedTracks,
                    artworkRevision: artworkRevision
                )
            )
        case .artist(let key):
            guard let entry = libraryVM.artistEntries.first(where: { $0.canonicalName == key }) else {
                return nil
            }
            let albumCount = libraryVM.albumEntries
                .filter { $0.primaryArtistCanonicalName == key }
                .count
            config = .artist(
                entry,
                stats: ArtistDerivedStats(
                    trackCount: displayedTracks.count,
                    albumCount: albumCount,
                    totalDuration: displayedTotalDuration
                )
            )
        case .album(let key):
            guard let entry = libraryVM.albumEntries.first(where: { $0.canonicalKey == key }) else {
                return nil
            }
            let fallbackArtwork = displayedTracks.first?.artworkData.flatMap {
                ArtworkLoader.headerPreviewImage(data: $0, maxPixelSize: 320)
            }
            config = .album(
                entry,
                stats: AlbumDerivedStats(
                    artistName: entry.primaryArtistDisplayName,
                    trackCount: displayedTracks.count,
                    totalDuration: displayedTotalDuration,
                    artworkImage: fallbackArtwork
                )
            )
        }

        guard let config else { return nil }
        return PlaylistPageHeaderModel(
            config: config,
            artworkIdentity: config.artworkIdentity,
            artwork: nil
        )
    }

    private func restoreScrollIfNeeded() {
        guard let libraryVM, let page else { return }
        let playlistID = libraryVM.selectedPlaylist?.id
        let restoreID = uiState?.consumeLibraryRestoreTarget(for: playlistID)

        guard let restoreID, page.rows.contains(where: { $0.id == restoreID }) else {
            listScrollPositionID = nil
            return
        }

        Task { @MainActor in
            self.listScrollPositionID = restoreID
        }
    }

    private func updateLibrarySnapshot() {
        guard let libraryVM, let uiState, let page else { return }
        let firstID = page.rows.first?.id
        let userScrolled = {
            guard let position = listScrollPositionID, let firstID else { return false }
            return position != firstID
        }()

        uiState.rememberLibraryContext(
            playlistID: libraryVM.selectedPlaylist?.id,
            scrollTrackID: listScrollPositionID,
            userScrolled: userScrolled
        )
    }

    private func syncPlayerQueueIfNeeded(with tracks: [Track], selectionIdentity: String) {
        guard let playerVM else { return }
        guard playerVM.activeLibraryQueueSource == .librarySelection(selectionIdentity) else {
            lastQueueTrackIDs = []
            return
        }
        let trackIDs = tracks.map(\.id)
        guard trackIDs != lastQueueTrackIDs else { return }
        lastQueueTrackIDs = trackIDs
        playerVM.updateQueueTracks(tracks)
    }

    private func currentDisplayedTracks(
        selection: LibrarySelection,
        libraryVM: LibraryViewModel
    ) -> [Track] {
        switch selection {
        case .allSongs:
            return libraryVM.allTracks.filter { $0.availability != .missing }
        case .playlist(let id):
            return libraryVM.playlists.first(where: { $0.id == id })?.tracks.filter {
                $0.availability != .missing
            } ?? []
        case .artist(let key):
            return libraryVM.allTracks.filter {
                LibraryNormalization.normalizeArtist($0.artist) == key
                    && $0.availability != .missing
            }
        case .album(let key):
            return libraryVM.allTracks.filter {
                LibraryNormalization.normalizedAlbumKey(album: $0.album, artist: $0.artist) == key
                    && $0.availability != .missing
            }
        }
    }

    private func pageSourceFingerprint(
        for tracks: [Track],
        libraryVM: LibraryViewModel
    ) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        hash ^= UInt64(tracks.count)
        hash &*= 1_099_511_628_211

        let step = max(1, tracks.count / 32)
        for index in stride(from: 0, to: tracks.count, by: step) {
            let track = tracks[index]
            let uuid = track.id.uuid
            withUnsafeBytes(of: uuid) { raw in
                for byte in raw {
                    hash ^= UInt64(byte)
                    hash &*= 1_099_511_628_211
                }
            }
            hash ^= UInt64(track.duration.bitPattern)
            hash &*= 1_099_511_628_211
        }

        hash ^= UInt64(libraryVM.totalTrackCount)
        hash &*= 1_099_511_628_211
        hash ^= UInt64(bitPattern: Int64(libraryVM.refreshTrigger))
        hash &*= 1_099_511_628_211
        hash ^= UInt64(bitPattern: Int64(libraryVM.trackUpdateEvent?.revision ?? 0))
        hash &*= 1_099_511_628_211

        return String(hash, radix: 16)
    }

    private func normalizedSearch(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectionIdentity(for selection: LibrarySelection) -> String {
        switch selection {
        case .allSongs:
            return "allSongs"
        case .playlist(let id):
            return "playlist-\(id.uuidString)"
        case .artist(let key):
            return "artist-\(key)"
        case .album(let key):
            return "album-\(key)"
        }
    }

    private static func buildPageResult(
        displayedTracks: [Track],
        entries: [SortableTrackEntry],
        searchText: String,
        sortKey: TrackSortKey,
        sortOrder: TrackSortOrder
    ) async -> BuildResult {
        await Task.detached(priority: .userInitiated) {
            let filteredEntries: [SortableTrackEntry]
            if searchText.isEmpty {
                filteredEntries = entries
            } else {
                filteredEntries = entries.filter {
                    $0.title.localizedCaseInsensitiveContains(searchText)
                }
            }

            let sortedFiltered = filteredEntries.sorted {
                compareSortableTracks($0, $1, sortKey: sortKey, sortOrder: sortOrder)
            }
            let queueEntries = searchText.isEmpty
                ? sortedFiltered
                : entries.sorted {
                    compareSortableTracks($0, $1, sortKey: sortKey, sortOrder: sortOrder)
                }

            let displayedTrackByID = Dictionary(uniqueKeysWithValues: displayedTracks.map { ($0.id, $0) })
            let rowRecords = sortedFiltered.compactMap { entry -> PlaylistPageRowRecord? in
                guard let track = displayedTrackByID[entry.id] else { return nil }
                return PlaylistPageRowRecord(
                    id: track.id,
                    title: track.title,
                    artist: track.artist,
                    durationText: formatDuration(track.duration),
                    artworkIdentity: PlaylistArtworkPipeline.rowSourceIdentity(
                        trackID: track.id,
                        artworkData: track.artworkData
                    ),
                    isMissing: track.availability == .missing
                )
            }

            let queueTrackIDs = queueEntries.map(\.id)
            let queueIndexMap = Dictionary(uniqueKeysWithValues: queueTrackIDs.enumerated().map {
                ($0.element, $0.offset)
            })
            let displayedTotalDuration = displayedTracks.reduce(0) { $0 + $1.duration }

            return BuildResult(
                rowRecords: rowRecords,
                queueTrackIDs: queueTrackIDs,
                queueIndexMap: queueIndexMap,
                displayedTrackCount: displayedTracks.count,
                filteredTrackCount: filteredEntries.count,
                displayedTotalDuration: displayedTotalDuration
            )
        }.value
    }

    private nonisolated static func compareSortableTracks(
        _ lhs: SortableTrackEntry,
        _ rhs: SortableTrackEntry,
        sortKey: TrackSortKey,
        sortOrder: TrackSortOrder
    ) -> Bool {
        let result: ComparisonResult

        switch sortKey {
        case .importedAt:
            result = compareDates(lhs.importedAt ?? lhs.addedAt, rhs.importedAt ?? rhs.addedAt)
        case .addedAt:
            result = compareDates(
                lhs.playlistItemAddedAt ?? lhs.importedAt ?? lhs.addedAt,
                rhs.playlistItemAddedAt ?? rhs.importedAt ?? rhs.addedAt
            )
        case .title:
            result = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        case .artist:
            result = lhs.artist.localizedCaseInsensitiveCompare(rhs.artist)
        case .duration:
            result = compareDoubles(lhs.duration, rhs.duration)
        case .playCount:
            result = compareInts(lhs.playCount, rhs.playCount)
        case .preference:
            result = compareDoubles(lhs.preferenceScore, rhs.preferenceScore)
        }

        if result == .orderedSame {
            let titleResult = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleResult != .orderedSame {
                return titleResult == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        return sortOrder == .ascending
            ? result == .orderedAscending
            : result == .orderedDescending
    }

    private nonisolated static func compareDates(_ lhs: Date, _ rhs: Date) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private nonisolated static func compareDoubles(_ lhs: Double, _ rhs: Double) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private nonisolated static func compareInts(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func normalizedPlayCount(for track: Track) -> Int {
        max(track.preferenceStats.playCount, 0)
    }

    private static func normalizedPreferenceScore(for track: Track) -> Double {
        let score = track.preferenceScore
        return score.isFinite ? score : 0
    }

    private nonisolated static func formatDuration(_ duration: Double) -> String {
        guard duration.isFinite, duration > 0 else { return "0:00" }
        let totalSeconds = Int(duration.rounded(.down))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
