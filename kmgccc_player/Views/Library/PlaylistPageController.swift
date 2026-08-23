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

    private struct PageTrackSource: Sendable {
        let id: UUID
        let title: String
        let artist: String
        let duration: Double
        let artworkData: Data?
        let libraryRootSnapshot: String
        let artworkFileName: String?
        let isMissing: Bool
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

    private struct HeaderColorRequestKey: Equatable {
        let artworkIdentity: String
        let sourceKey: String
    }

    private enum FadeTiming {
        /// Crossfade duration for header artwork (old layer stays visible during fade)
        static let headerCrossfadeDuration: Double = 0.26
        /// Crossfade duration for halo (slower + delayed for softer appearance)
        static let haloReadyDelayNanoseconds: UInt64 = 70_000_000
        static let haloReadyFadeDuration: Double = 0.54
        static let haloSeedPixelSide: Int = 128
    }

    private enum RevealScroll {
        /// Aggressive ease-out with a long, gentle tail: the scroll leaps forward
        /// almost immediately (fast acceleration) then creeps the last few percent
        /// into the target row over a long deceleration. Slower and more non-linear
        /// than a plain easeOut for a silkier reveal.
        static let animation: Animation = .timingCurve(0.1, 1.0, 0.3, 1.0, duration: 0.75)
        /// Delay after the scroll is triggered before the highlight pulse fires,
        /// chosen to land near the end of the scroll animation.
        static let highlightDelayMilliseconds: UInt64 = 620
        /// Delay before applying the scroll position, so a freshly-created scroll
        /// view (after a playlist switch) has time to lay out its rows. Without
        /// this, the new ScrollView may ignore the initial scrollPosition binding.
        static let scrollStabilizationDelayMilliseconds: UInt64 = 50
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

    // MARK: - Header Color Extraction (independent of global ThemeStore)
    /// Accent color derived from the current header artwork.
    /// Updated asynchronously when header artwork changes.
    private(set) var headerAccentColor: Color = ThemeStore.shared.accentColor
    /// Full semantic palette derived from the current header artwork.
    private(set) var headerSemanticPalette: SemanticPalette?
    /// Header foreground may be restored from a persistent cache before the
    /// full semantic palette is rehydrated from artwork data.
    private(set) var headerForegroundPalette: AppForegroundPalette?
    private(set) var isHeaderColorReady = false
    private var headerColorTask: Task<Void, Never>?
    private var headerLoadDispatchTask: Task<Void, Never>?
    private var lastHeaderColorIdentity: String?
    private var lastHeaderColorChecksum: UInt64 = 0
    private var lastHeaderArtworkData: Data?
    private var lastHeaderColorScheme: ColorScheme?
    private var inFlightHeaderColorRequestKey: HeaderColorRequestKey?

    // MARK: - Halo Crossfade State (low-resolution seed image)
    private(set) var haloCurrentImage: NSImage?
    private(set) var haloIncomingImage: NSImage?
    private(set) var haloSourceBlendOpacity: Double = 1
    private(set) var haloPresentationOpacity: Double = 0

    var searchText = ""
    var listScrollPositionID: UUID?
    var isMultiselectMode = false
    var selectedTrackIDs: Set<UUID> = []
    var selectionAnchorTrackID: UUID?
    private(set) var collectionListSelection: LibrarySelection?
    private(set) var collectionVisibleItemIDs: [UUID] = []
    private(set) var collectionCustomOrderSourceItemIDs: [UUID] = []
    private(set) var isCollectionListFiltering = false
    var rendersHeaderBackgroundInWindowLayer = false
    private(set) var isManualTrackReorderActive = false

    /// Track ID that should show a brief reveal-highlight pulse.
    /// Set after the scroll-to-now-playing animation lands, cleared automatically.
    private(set) var revealHighlightTrackID: UUID?

    let haloState = HeaderHaloState()

    private var libraryVM: LibraryViewModel?
    private var playerVM: PlayerViewModel?
    private var uiState: UIStateViewModel?
    private var headerColorExtractor: HeaderColorExtractor?
    private var playlistArtworkPipeline: PlaylistArtworkPipeline?

    private var rebuildTask: Task<Void, Never>?
    private var snapshotUpdateTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var headerResolveTask: Task<Void, Never>?
    private var headerUpgradeTask: Task<Void, Never>?
    private var headerHaloSeedTask: Task<Void, Never>?
    private var headerFadeTask: Task<Void, Never>?
    private var haloFadeTask: Task<Void, Never>?
    private var phaseTask: Task<Void, Never>?
    private var revealHighlightTask: Task<Void, Never>?
    private var revealScrollTask: Task<Void, Never>?
    private var deferredDisappearTask: Task<Void, Never>?
    private var activeLoadToken = UUID()
    private var phaseToken = UUID()
    private var headerResolveToken = UUID()
    private var lastQueueTrackIDs: [UUID] = []
    private var lastPrefetchBucket: Int?
    private var currentArtworkPresentationIdentity: String?
    private var didFadeHeaderIdentity: String?
    private var didFadeHaloIdentity: String?
    @ObservationIgnored
    private var artworkPrefetchTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var prefetchedArtworkKeys: Set<String> = []
    @ObservationIgnored
    private var latestTrackLookup: [UUID: Track] = [:]
    @ObservationIgnored
    private var activeViewTokens: Set<UUID> = []
    @ObservationIgnored
    private var lastPlaybackTrackChangeUptime: TimeInterval = 0
    @ObservationIgnored
    private var headerHeavyWorkBaselineUptime: TimeInterval = 0
    @ObservationIgnored
    private var hasObservedPlaybackTrackChangeSinceBaseline = false
    @ObservationIgnored
    private var pendingRevealTrackID: UUID?
    @ObservationIgnored
    private var pendingRevealAnimated = true
    /// True while a reveal scroll is armed (scheduled or animating). The scroll
    /// view's position binding checks this to avoid clobbering the target with
    /// intermediate/nil positions reported by a freshly-created ScrollView.
    @ObservationIgnored
    private(set) var isRevealScrollArmed = false

    func bind(
        libraryVM: LibraryViewModel,
        playerVM: PlayerViewModel,
        uiState: UIStateViewModel,
        cacheServices: LibraryCacheServices
    ) {
        self.libraryVM = libraryVM
        self.playerVM = playerVM
        self.uiState = uiState
        self.headerColorExtractor = cacheServices.headerColorExtractor
        self.playlistArtworkPipeline = cacheServices.playlistArtworkPipeline
    }

    func bindCollectionList(libraryVM: LibraryViewModel, uiState: UIStateViewModel) {
        self.libraryVM = libraryVM
        self.uiState = uiState
    }

    func appear(token: UUID) {
        guard let libraryVM else { return }
        activeViewTokens.insert(token)
        deferredDisappearTask?.cancel()
        deferredDisappearTask = nil
        haloState.beginSession(selectionIdentity: selectionIdentity(for: libraryVM.currentSelection))
        resetHeaderHeavyWorkDeferralBaseline()
        activateFirstPaintPhases(for: libraryVM.currentSelection)
        scheduleRebuild(reason: "appear", restoreScroll: true)
    }

    func disappear(token: UUID) {
        activeViewTokens.remove(token)
        guard activeViewTokens.isEmpty else { return }
        deferredDisappearTask?.cancel()
        deferredDisappearTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            guard self.activeViewTokens.isEmpty else { return }
            self.cancelAllTasks(clearPage: true)
            self.phase = .idle
            self.page = nil
            self.lastQueueTrackIDs = []
            self.resetArtworkPresentation(force: true, identity: nil)
            self.resetHeaderHeavyWorkDeferralBaseline()
            self.haloState.clear()
            self.deferredDisappearTask = nil
        }
    }

    func handleSelectionChange(_ selection: LibrarySelection) {
        clearMultiselectState()
        if collectionListSelection != selection {
            collectionListSelection = nil
            collectionVisibleItemIDs = []
            collectionCustomOrderSourceItemIDs = []
            isCollectionListFiltering = false
        }
        resetHeaderHeavyWorkDeferralBaseline()
        beginSelectionTransition(to: selection)
        scheduleRebuild(reason: "selection", restoreScroll: true)
    }

    func handleSearchChange() {
        if isSearchFilteringTracks {
            clearMultiselectState()
        }
        scheduleRebuild(reason: "search", debounceNanoseconds: 150_000_000)
    }

    func prepareForSearchInteraction() {
        if isMultiselectMode {
            clearMultiselectState()
        }
    }

    func clearSearchAndRebuildIfNeeded(reason: String) {
        let hadSearch = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hadSearch {
            searchText = ""
            scheduleRebuild(reason: reason, restoreScroll: true)
        }
    }

    func handleSortChange(reason: String) {
        scheduleRebuild(reason: reason)
    }

    func handleLibraryRefresh(reason: String, restoreScroll: Bool) {
        scheduleRebuild(reason: reason, restoreScroll: restoreScroll)
    }

    func updateScrollPosition(_ trackID: UUID?) {
        guard !isManualTrackReorderActive else { return }
        listScrollPositionID = trackID
        scheduleSnapshotUpdate()
    }

    func requestRevealTrack(_ trackID: UUID, animated: Bool, deferUntilRebuild: Bool = false) {
        guard !isManualTrackReorderActive else { return }
        pendingRevealTrackID = trackID
        pendingRevealAnimated = animated
        // When the caller is about to switch to a different selection (e.g.
        // from the Home page, whose rows contain every track), skip the
        // immediate reveal: it would consume the pending target in the wrong
        // page. The next `applyPageModel` for the target selection will pick
        // up `pendingRevealTrackID` and scroll then.
        if !deferUntilRebuild {
            revealPendingTrackIfPossible()
        }
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
        selectionAnchorTrackID = nil
        isManualTrackReorderActive = false
    }

    func registerCollectionList(
        selection: LibrarySelection,
        visibleItemIDs: [UUID],
        customOrderSourceItemIDs: [UUID],
        isFiltering: Bool
    ) {
        if collectionListSelection != selection {
            clearMultiselectState()
        }
        collectionListSelection = selection
        collectionVisibleItemIDs = visibleItemIDs
        collectionCustomOrderSourceItemIDs = customOrderSourceItemIDs
        isCollectionListFiltering = isFiltering

        let visibleSet = Set(visibleItemIDs)
        if !selectedTrackIDs.isSubset(of: visibleSet) {
            selectedTrackIDs.formIntersection(visibleSet)
            if let anchor = selectionAnchorTrackID, !visibleSet.contains(anchor) {
                selectionAnchorTrackID = selectedTrackIDs.first
            }
        }
    }

    func unregisterCollectionList(selection: LibrarySelection) {
        guard collectionListSelection == selection else { return }
        clearMultiselectState()
        collectionListSelection = nil
        collectionVisibleItemIDs = []
        collectionCustomOrderSourceItemIDs = []
        isCollectionListFiltering = false
    }

    /// Clears page-local interaction state only.
    ///
    /// Safe to call during an in-place selection transition (e.g. switching
    /// from one playlist to another while the detail view stays mounted): the
    /// environment bindings (`libraryVM` / `playerVM` / `uiState`) and
    /// `activeViewTokens` must stay intact, otherwise the follow-up rebuild in
    /// `performRebuild` bails out on its `guard let libraryVM` and the page
    /// never renders again. Use `releaseForSessionTeardown()` when the hosting
    /// window or library session is going away for real.
    func releaseSelectionStateForTeardown() {
        isMultiselectMode = false
        selectedTrackIDs.removeAll()
        selectionAnchorTrackID = nil
        collectionListSelection = nil
        collectionVisibleItemIDs = []
        collectionCustomOrderSourceItemIDs = []
        isCollectionListFiltering = false
        listScrollPositionID = nil
        lastPrefetchBucket = nil
        isManualTrackReorderActive = false
    }

    /// Full teardown for the end of a view/session lifetime (library switch,
    /// window release). Cancels in-flight work and drops all environment
    /// references so the controller does not pin the outgoing session's
    /// view models and caches.
    func releaseForSessionTeardown() {
        cancelAllTasks(clearPage: true)
        releaseSelectionStateForTeardown()
        libraryVM = nil
        playerVM = nil
        uiState = nil
        headerColorExtractor = nil
        activeViewTokens.removeAll()
    }

    @discardableResult
    func toggleMultiselectModeIfAllowed() -> Bool {
        if isSearchFilteringCurrentList || !hasMultiselectRowsForCurrentSelection {
            clearMultiselectState()
            return false
        }

        if isMultiselectMode {
            clearMultiselectState()
            return false
        }

        isMultiselectMode = true
        return true
    }

    func beginMultiselectSelection(at trackID: UUID) {
        guard !isSearchFilteringTracks else { return }
        isMultiselectMode = true
        selectedTrackIDs.insert(trackID)
        selectionAnchorTrackID = trackID
    }

    func handleMultiselectItemTap(itemID: UUID, extendingRange: Bool) {
        guard isMultiselectMode else { return }
        guard !isSearchFilteringCurrentList else {
            clearMultiselectState()
            return
        }

        if extendingRange,
           let anchorID = selectionAnchorTrackID,
           let anchorIndex = collectionVisibleItemIDs.firstIndex(of: anchorID),
           let currentIndex = collectionVisibleItemIDs.firstIndex(of: itemID)
        {
            let bounds = anchorIndex <= currentIndex
                ? anchorIndex...currentIndex
                : currentIndex...anchorIndex
            selectedTrackIDs.formUnion(collectionVisibleItemIDs[bounds])
            return
        }

        if selectedTrackIDs.contains(itemID) {
            selectedTrackIDs.remove(itemID)
        } else {
            selectedTrackIDs.insert(itemID)
        }
        selectionAnchorTrackID = itemID
    }

    func handleMultiselectRowTap(trackID: UUID, extendingRange: Bool) {
        guard isMultiselectMode else { return }
        guard !isSearchFilteringTracks else {
            clearMultiselectState()
            return
        }

        if extendingRange,
           let anchorTrackID = selectionAnchorTrackID,
           let visibleRows = page?.rows,
           let anchorIndex = visibleRows.firstIndex(where: { $0.id == anchorTrackID }),
           let currentIndex = visibleRows.firstIndex(where: { $0.id == trackID })
        {
            let bounds = anchorIndex <= currentIndex
                ? anchorIndex...currentIndex
                : currentIndex...anchorIndex
            selectedTrackIDs.formUnion(visibleRows[bounds].map(\.id))
            return
        }

        if selectedTrackIDs.contains(trackID) {
            selectedTrackIDs.remove(trackID)
        } else {
            selectedTrackIDs.insert(trackID)
        }
        selectionAnchorTrackID = trackID
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
        
        let bucket = startIndex / 8
        guard bucket != lastPrefetchBucket else { return }
        lastPrefetchBucket = bucket

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        
        let start = max(0, startIndex - 12)
        let end = min(page.rows.count, startIndex + 40)
        guard start < end else { return }

        let rows = Array(page.rows[start..<end])
        var requests = rows.map {
            PlaylistArtworkPipeline.rowLowRequest(
                trackID: $0.id,
                artworkData: $0.artworkData,
                artworkFileURL: $0.artworkFileURL,
                artworkIdentity: $0.artworkIdentity,
                logicalSize: Constants.Layout.artworkSmallSize,
                scale: scale
            )
        }
        requests.append(contentsOf: rows.prefix(24).map {
            PlaylistArtworkPipeline.rowHighRequest(
                trackID: $0.id,
                artworkData: $0.artworkData,
                artworkFileURL: $0.artworkFileURL,
                artworkIdentity: $0.artworkIdentity,
                logicalSize: Constants.Layout.artworkSmallSize,
                scale: scale
            )
        })
        startArtworkPrefetch(
            key: "\(page.selectionIdentity)-bucket-\(bucket)-\(page.sourceFingerprint)",
            requests: requests
        )
    }

    func applyTargetedTrackRefresh(trackID _: UUID) {
        scheduleRebuild(reason: "track-update")
    }

    func latestTrackFromLibrary(trackID: UUID) -> Track? {
        if let track = latestTrackLookup[trackID] {
            return track
        }
        guard let libraryVM else { return nil }
        if let track = libraryVM.allTracks.first(where: { $0.id == trackID }) {
            return track
        }
        return page?.queueTracks.first(where: { $0.id == trackID })
    }

    func queueStartIndex(for trackID: UUID) -> Int {
        page?.queueIndexMap[trackID] ?? 0
    }

    var canManuallyReorderCurrentTracks: Bool {
        guard let libraryVM else { return false }
        return libraryVM.supportsCustomTrackOrder(for: libraryVM.currentSelection)
    }

    var canManuallyReorderCurrentCollection: Bool {
        guard let libraryVM else { return false }
        return libraryVM.supportsCustomCollectionOrder(for: libraryVM.currentSelection)
    }

    var hasMultiselectRowsForCurrentSelection: Bool {
        if isCurrentSelectionCollectionList {
            return !collectionVisibleItemIDs.isEmpty
        }
        return page?.rows.isEmpty == false
    }

    var isSearchFilteringCurrentList: Bool {
        if isCurrentSelectionCollectionList {
            return isCollectionListFiltering
        }
        return isSearchFilteringTracks
    }

    private var isCurrentSelectionCollectionList: Bool {
        guard let libraryVM else { return false }
        return collectionListSelection == libraryVM.currentSelection
            && libraryVM.supportsCustomCollectionOrder(for: libraryVM.currentSelection)
    }

    var isSearchFilteringTracks: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func beginManualTrackReorderInteraction() {
        isManualTrackReorderActive = true
        listScrollPositionID = nil
        snapshotUpdateTask?.cancel()
    }

    func endManualTrackReorderInteraction() {
        isManualTrackReorderActive = false
        listScrollPositionID = nil
    }

    func activateCustomSortFromCurrentDisplay(reason: String) {
        if activateCustomCollectionSortFromCurrentDisplay(reason: reason) {
            return
        }

        guard let libraryVM, canManuallyReorderCurrentTracks else { return }
        let visibleTrackIDs = isSearchFilteringTracks
            ? page?.queueTracks.map(\.id) ?? []
            : page?.rows.map(\.id) ?? []
        guard !visibleTrackIDs.isEmpty else { return }
        libraryVM.initializeCustomTrackOrderForCurrentSelectionIfNeeded(
            displayedTrackIDs: visibleTrackIDs
        )
        if libraryVM.trackSortKey != .custom {
            libraryVM.trackSortKey = .custom
        }
        scheduleRebuild(reason: reason)
    }

    @discardableResult
    private func activateCustomCollectionSortFromCurrentDisplay(reason: String) -> Bool {
        guard
            let libraryVM,
            isCurrentSelectionCollectionList,
            canManuallyReorderCurrentCollection
        else {
            return false
        }

        let sourceIDs = collectionCustomOrderSourceItemIDs.isEmpty
            ? collectionVisibleItemIDs
            : collectionCustomOrderSourceItemIDs
        guard !sourceIDs.isEmpty else { return true }

        let didSave = libraryVM.initializeCustomCollectionOrderForCurrentSelectionIfNeeded(
            displayedItemIDs: sourceIDs
        )
        let didSwitchSort = libraryVM.activateCustomCollectionSortForCurrentSelection()
        if didSave || didSwitchSort {
            collectionCustomOrderSourceItemIDs = sourceIDs
        }
        return true
    }

    func commitManualTrackOrder(orderedTrackIDs: [UUID], reason: String) {
        guard let libraryVM, canManuallyReorderCurrentTracks else { return }
        guard !orderedTrackIDs.isEmpty else { return }

        let didSave = libraryVM.saveCustomTrackOrderForCurrentSelection(trackIDs: orderedTrackIDs)
        let didSwitchSort = libraryVM.trackSortKey != .custom
        if didSwitchSort {
            libraryVM.trackSortKey = .custom
        }

        guard didSave || didSwitchSort else { return }
        scheduleRebuild(reason: reason)
    }

    func commitManualCollectionOrder(orderedItemIDs: [UUID], reason: String) {
        guard let libraryVM, canManuallyReorderCurrentCollection else { return }
        guard !orderedItemIDs.isEmpty else { return }

        let didSave = libraryVM.saveCustomCollectionOrderForCurrentSelection(itemIDs: orderedItemIDs)
        let didSwitchSort = libraryVM.activateCustomCollectionSortForCurrentSelection()
        if didSave || didSwitchSort {
            collectionCustomOrderSourceItemIDs = orderedItemIDs
        }
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
        headerHaloSeedTask?.cancel()
        headerLoadDispatchTask?.cancel()
        headerFadeTask?.cancel()
        haloFadeTask?.cancel()
        prefetchTask?.cancel()
        for task in artworkPrefetchTasks.values {
            task.cancel()
        }
        artworkPrefetchTasks.removeAll()
        prefetchedArtworkKeys.removeAll()
        latestTrackLookup.removeAll()
        snapshotUpdateTask?.cancel()
        rebuildTask?.cancel()
        revealScrollTask?.cancel()
        revealHighlightTask?.cancel()
        isRevealScrollArmed = false
        phaseToken = UUID()
        headerResolveToken = UUID()
        isManualTrackReorderActive = false
        areRowSecondaryInteractionsEnabled = false
        areRowArtworkLoadsEnabled = false
        isRowArtworkPrefetchEnabled = false
        isHeaderEffectsEnabled = false
        headerIncomingOpacity = 0
        haloSourceBlendOpacity = 1
        haloPresentationOpacity = 0
        inFlightHeaderColorRequestKey = nil
    }

    private func activateFirstPaintPhases(for selection: LibrarySelection) {
        let firstPaintToken = FirstUseHitchDiagnostics.begin("PlaylistPageController.firstPaint", detail: "selection=\(selection)")
        phaseTask?.cancel()
        let playbackActive = playerVM?.isPlaying == true
        areRowSecondaryInteractionsEnabled = false
        areRowArtworkLoadsEnabled = true
        isRowArtworkPrefetchEnabled = false
        let hasDetailHeader: Bool = {
            switch selection {
            case .playlist, .artist, .album:
                return true
            case .home, .allSongs, .allPlaylists, .allAlbums, .allArtists:
                return false
            }
        }()
        isHeaderEffectsEnabled = hasDetailHeader && !playbackActive

        let token = UUID()
        phaseToken = token
        phaseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 130_000_000)
            guard !Task.isCancelled, self.phaseToken == token else { return }
            self.areRowSecondaryInteractionsEnabled = true
            if !playbackActive {
                self.isRowArtworkPrefetchEnabled = true
            } else {
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled, self.phaseToken == token else { return }
                self.isRowArtworkPrefetchEnabled = true
            }

            guard hasDetailHeader else { return }
            try? await Task.sleep(nanoseconds: playbackActive ? 500_000_000 : 140_000_000)
            guard !Task.isCancelled, self.phaseToken == token else { return }
            self.isRowArtworkPrefetchEnabled = true
            self.isHeaderEffectsEnabled = true
            LyricsRuntimeProfile.increment("header.effectsEnabled.true")
        }
        FirstUseHitchDiagnostics.end(firstPaintToken)
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
        let opToken = FirstUseHitchDiagnostics.begin("PlaylistPageController.rebuild", detail: "reason=\(reason)")
        defer { FirstUseHitchDiagnostics.end(opToken) }

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
        let isSearching = !trimmedSearch.isEmpty
        let displayedTrackIDs = displayedTracks.map(\.id)
        let customOrderIDs = libraryVM.trackSortKey == .custom
            ? libraryVM.customTrackOrderIDsForCurrentSelection(displayedTrackIDs: displayedTrackIDs)
            : nil
        let sortOrderCacheComponent = libraryVM.trackSortKey == .custom
            ? "custom:\(libraryVM.trackSortOrder.rawValue):\(libraryVM.customTrackOrderSignatureForCurrentSelection(displayedTrackIDs: displayedTrackIDs))"
            : libraryVM.trackSortOrder.rawValue

        let modelKey = await PlaylistPageModelCacheService.shared.cacheKey(
            selectionIdentity: selectionIdentity,
            sourceFingerprint: sourceFingerprint,
            searchText: trimmedSearch,
            sortKeyRawValue: libraryVM.trackSortKey.rawValue,
            sortOrderRawValue: sortOrderCacheComponent
        )

        if !isSearching,
           let cached = await PlaylistPageModelCacheService.shared.model(for: modelKey),
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

        let sortableEntries = displayedTracks.map { track in
            let stats = libraryVM.preferenceStats(for: track.id)
            return SortableTrackEntry(
                id: track.id,
                title: track.title,
                artist: track.artist,
                duration: track.duration,
                playCount: max(stats.playCount, 0),
                preferenceScore: stats.preferenceScoreCache.isFinite
                    ? stats.preferenceScoreCache
                    : 0,
                addedAt: track.addedAt,
                importedAt: track.importedAt,
                playlistItemAddedAt: playlistItemAddedAtMap?[track.id]
            )
        }
        let searchHits = isSearching
            ? await searchHits(
                for: trimmedSearch,
                displayedTrackIDs: displayedTracks.map(\.id),
                libraryVM: libraryVM
            )
            : [:]
        let pageTrackSources = displayedTracks.map {
            PageTrackSource(
                id: $0.id,
                title: $0.title,
                artist: $0.artist,
                duration: $0.duration,
                artworkData: $0.artworkData,
                libraryRootSnapshot: $0.libraryRootSnapshot,
                artworkFileName: $0.artworkFileName,
                // Grey out every non-playable state (missing file, offline
                // volume, denied permission), not just .missing, so the row
                // always reflects what playback can actually do.
                isMissing: !$0.availability.isPlayable
            )
        }

        let buildResult = await Self.buildPageResult(
            displayedTracks: pageTrackSources,
            entries: sortableEntries,
            searchText: trimmedSearch,
            searchHits: searchHits,
            sortKey: libraryVM.trackSortKey,
            sortOrder: libraryVM.trackSortOrder,
            customOrderIDs: customOrderIDs
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

        if !isSearching {
            await PlaylistPageModelCacheService.shared.store(
                PlaylistPageModelCacheEntry(
                    key: modelKey,
                    selectionIdentity: selectionIdentity,
                    sourceFingerprint: sourceFingerprint,
                    searchText: trimmedSearch,
                    sortKeyRawValue: libraryVM.trackSortKey.rawValue,
                    sortOrderRawValue: sortOrderCacheComponent,
                    displayedTrackIDs: displayedTrackIDs,
                    rowRecords: buildResult.rowRecords,
                    queueTrackIDs: buildResult.queueTrackIDs,
                    queueIndexMap: buildResult.queueIndexMap,
                    displayedTrackCount: buildResult.displayedTrackCount,
                    filteredTrackCount: buildResult.filteredTrackCount,
                    displayedTotalDuration: buildResult.displayedTotalDuration,
                    cachedAt: Date()
                )
            )
        }

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
        if let selectionAnchorTrackID,
           !pageModel.rows.contains(where: { $0.id == selectionAnchorTrackID })
        {
            self.selectionAnchorTrackID = nil
        }
        latestTrackLookup = Dictionary(uniqueKeysWithValues: pageModel.queueTracks.map { ($0.id, $0) })
        lastPrefetchBucket = nil
        isSelectionTransitioning = false
        phase = .ready

        if revealPendingTrackIfPossible() {
            // The explicit reveal request owns the scroll target for this rebuild.
        } else if restoreScroll {
            restoreScrollIfNeeded()
        } else if listScrollPositionID != nil, !(pageModel.rows.contains { $0.id == listScrollPositionID }) {
            listScrollPositionID = nil
        }

        updateLibrarySnapshot()
        syncPlayerQueueIfNeeded(
            with: pageModel.queueTracks,
            selectionIdentity: pageModel.selectionIdentity
        )
        scheduleInitialArtworkWarmup(for: pageModel)
        scheduleHeaderArtworkLoad(expectedSelectionIdentity: pageModel.selectionIdentity)
    }

    private func scheduleHeaderArtworkLoad(expectedSelectionIdentity: String) {
        headerLoadDispatchTask?.cancel()
        headerLoadDispatchTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard self.page?.selectionIdentity == expectedSelectionIdentity else { return }
            self.loadHeaderArtwork()
        }
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
        headerHaloSeedTask?.cancel()
        let request = header.config.artworkRequest
        guard let artworkResolver = libraryVM?.detailHeaderArtworkResolver else { return }
        let selectionIdentity = page.selectionIdentity
        let loadToken = UUID()
        let playbackActive = playerVM?.isPlaying == true
        headerResolveToken = loadToken
        resetHeaderHeavyWorkDeferralBaseline()

        headerResolveTask = Task(priority: playbackActive ? .utility : .userInitiated) { @MainActor in
            let immediateStart = ProcessInfo.processInfo.systemUptime
            let immediate = artworkResolver.resolveImmediately(for: request)
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
            let resolved = await artworkResolver.resolveDeferredArtwork(for: request)
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
        guard let currentPage = page, currentPage.selectionIdentity == selectionIdentity else { return }
        guard let currentHeader = currentPage.header else { return }

        // Immediate stage: publish what we have right away.
        if let image = resolved?.image {
            LyricsRuntimeProfile.increment("header.applyResolvedArtwork.image")
            publishHeaderImage(image, identity: artworkIdentity, resolveToken: resolveToken)
        }

        let payload = headerArtworkPayload(
            request: currentHeader.config.artworkRequest,
            resolved: resolved
        )

        // Kick off header color extraction independently of the global ThemeStore.
        // Uses payload.data or falls back to resolved image data for the color source.
        startHeaderColorExtraction(
            payload: payload,
            artworkIdentity: artworkIdentity,
            resolveToken: resolveToken
        )

        guard payload.data != nil || payload.fileURL != nil else { return }

        startImmediateHaloSeedLoad(
            payload: payload,
            artworkIdentity: artworkIdentity,
            selectionIdentity: selectionIdentity,
            resolveToken: resolveToken
        )

        headerUpgradeTask?.cancel()
        let shouldDeferHeavyUpgrade = shouldDeferHeaderHeavyWork
        headerUpgradeTask = Task { @MainActor in
            if shouldDeferHeavyUpgrade {
                await self.waitForHeaderHeavyWorkQuietWindow(resolveToken: resolveToken)
                guard !Task.isCancelled else { return }
                guard self.headerResolveToken == resolveToken else { return }
            }
            let upgradeStart = ProcessInfo.processInfo.systemUptime
            let headerOpToken = FirstUseHitchDiagnostics.begin("PlaylistPageController.headerArtwork", detail: "identity=\(artworkIdentity.prefix(8))")
            let headerRequest = PlaylistArtworkPipeline.headerRequest(
                artworkIdentity: artworkIdentity,
                artworkData: payload.data,
                fileURL: payload.fileURL
            )
            let shouldLoadHaloSeed = self.isHeaderEffectsEnabled
            let haloSeedPixelSide = FadeTiming.haloSeedPixelSide
            let haloSeedRequest = shouldLoadHaloSeed
                ? PlaylistArtworkPipeline.haloSeedRequest(
                    artworkIdentity: artworkIdentity,
                    artworkData: payload.data,
                    fileURL: payload.fileURL,
                    pixelSide: haloSeedPixelSide
                )
                : nil
            guard let pipeline = self.playlistArtworkPipeline else { return }
            async let upgradedHeader = pipeline.load(headerRequest)
            async let upgradedHaloSeed: NSImage? = {
                guard let haloSeedRequest else { return nil }
                return await pipeline.load(haloSeedRequest)
            }()

            let headerImage = await upgradedHeader
            let haloSeedImage = await upgradedHaloSeed
            LyricsRuntimeProfile.increment("header.pipelineUpgrade.count")
            LyricsRuntimeProfile.addDuration(
                "header.pipelineUpgrade",
                ms: (ProcessInfo.processInfo.systemUptime - upgradeStart) * 1000
            )
            guard !Task.isCancelled else { FirstUseHitchDiagnostics.end(headerOpToken); return }
            guard self.headerResolveToken == resolveToken else { FirstUseHitchDiagnostics.end(headerOpToken); return }
            guard self.page?.selectionIdentity == selectionIdentity else { FirstUseHitchDiagnostics.end(headerOpToken); return }
            FirstUseHitchDiagnostics.end(headerOpToken)

            if let headerImage {
                self.publishHeaderImage(
                    headerImage,
                    identity: artworkIdentity,
                    resolveToken: resolveToken
                )
            }
            if self.isHeaderEffectsEnabled {
                self.publishHaloImage(
                    haloSeedImage ?? headerImage,
                    identity: artworkIdentity,
                    resolveToken: resolveToken
                )
            }
        }
    }

    private func scheduleInitialArtworkWarmup(for pageModel: PlaylistPageModel) {
        let playbackActive = playerVM?.isPlaying == true
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let lowPriorityRowCount = playbackActive ? 24 : 72
        let highPriorityRowCount = playbackActive ? 10 : 32
        let rows = Array(pageModel.rows.prefix(lowPriorityRowCount))
        var requests: [PlaylistArtworkRequest] = []
        requests.reserveCapacity(rows.count + min(rows.count, highPriorityRowCount))

        requests.append(contentsOf: rows.map {
            PlaylistArtworkPipeline.rowLowRequest(
                trackID: $0.id,
                artworkData: $0.artworkData,
                artworkFileURL: $0.artworkFileURL,
                artworkIdentity: $0.artworkIdentity,
                logicalSize: Constants.Layout.artworkSmallSize,
                scale: scale
            )
        })

        requests.append(contentsOf: rows.prefix(highPriorityRowCount).map {
            PlaylistArtworkPipeline.rowHighRequest(
                trackID: $0.id,
                artworkData: $0.artworkData,
                artworkFileURL: $0.artworkFileURL,
                artworkIdentity: $0.artworkIdentity,
                logicalSize: Constants.Layout.artworkSmallSize,
                scale: scale
            )
        })

        startArtworkPrefetch(
            key: "\(pageModel.selectionIdentity)-initial-\(pageModel.sourceFingerprint)",
            requests: requests,
            priority: playbackActive ? .background : .utility
        )

        if let currentTrackID = playerVM?.currentTrack?.id {
            prefetchAroundTrackID(currentTrackID)
        }
    }

    private func startHeaderColorExtraction(
        payload: HeaderArtworkPayload,
        artworkIdentity: String,
        resolveToken: UUID
    ) {
        let requestKey = HeaderColorRequestKey(
            artworkIdentity: artworkIdentity,
            sourceKey: headerColorSourceKey(for: payload)
        )
        if inFlightHeaderColorRequestKey == requestKey {
            noteHeaderColorDiscard(reason: "dedup", artworkIdentity: artworkIdentity)
            return
        }

        headerColorTask?.cancel()
        guard let headerColorExtractor else { return }
        headerColorExtractor.cancelPending()
        inFlightHeaderColorRequestKey = requestKey

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let cached = headerColorExtractor.cachedResult(artworkIdentity: artworkIdentity, isDark: isDark) {
            commitHeaderColor(
                accent: cached.accent,
                palette: cached.palette,
                foregroundPalette: cached.foreground,
                artworkIdentity: artworkIdentity,
                checksum: cached.checksum,
                scheme: isDark ? .dark : .light
            )
        } else if requestKey.sourceKey != "empty" {
            isHeaderColorReady = false
        }

        headerColorTask = Task(priority: .utility) { @MainActor in
            let colorOpToken = FirstUseHitchDiagnostics.begin(
                "PlaylistPageController.headerColor",
                detail: "identity=\(artworkIdentity.prefix(8))"
            )
            defer { FirstUseHitchDiagnostics.end(colorOpToken) }
            defer {
                if self.inFlightHeaderColorRequestKey == requestKey {
                    self.inFlightHeaderColorRequestKey = nil
                }
            }

            await Task.yield()
            guard !Task.isCancelled else { return }

            let resolvedData: Data? = await Task.detached(priority: .utility) { @Sendable () -> Data? in
                if let data = payload.data, !data.isEmpty { return data }
                if let fileURL = payload.fileURL,
                   FileManager.default.fileExists(atPath: fileURL.path) {
                    return try? Data(contentsOf: fileURL)
                }
                return nil
            }.value

            guard !Task.isCancelled else { return }
            guard self.headerResolveToken == resolveToken else {
                self.noteHeaderColorDiscard(reason: "stale-token", artworkIdentity: artworkIdentity)
                return
            }

            let checksum = resolvedData.map { ColorMath.fnv1a($0) } ?? 0
            let currentScheme = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ColorScheme.dark : ColorScheme.light
            if artworkIdentity == self.lastHeaderColorIdentity,
               checksum == self.lastHeaderColorChecksum,
               currentScheme == self.lastHeaderColorScheme
            {
                return
            }

            guard let data = resolvedData, !data.isEmpty else {
                self.lastHeaderArtworkData = nil
                self.commitHeaderColor(
                    accent: ThemeStore.shared.accentColor,
                    palette: nil,
                    foregroundPalette: nil,
                    artworkIdentity: artworkIdentity,
                    checksum: 0,
                    scheme: currentScheme
                )
                return
            }

            self.lastHeaderArtworkData = data

            let result = await headerColorExtractor.extract(
                from: data,
                artworkIdentity: artworkIdentity,
                isDark: currentScheme == .dark
            )
            guard !Task.isCancelled else { return }
            guard self.headerResolveToken == resolveToken else {
                self.noteHeaderColorDiscard(reason: "stale-result", artworkIdentity: artworkIdentity)
                return
            }

            if let result {
                self.commitHeaderColor(
                    accent: result.accent,
                    palette: result.palette,
                    foregroundPalette: result.palette.appForeground,
                    artworkIdentity: artworkIdentity,
                    checksum: checksum,
                    scheme: currentScheme
                )
            }
        }
    }

    private func headerColorSourceKey(for payload: HeaderArtworkPayload) -> String {
        if let data = payload.data, !data.isEmpty {
            return "data-\(data.count)-\(ArtworkDataFingerprint.sampledHash(for: data))"
        }
        if let fileURL = payload.fileURL {
            return "file-\(fileURL.path)"
        }
        return "empty"
    }

    private func commitHeaderColor(
        accent: Color,
        palette: SemanticPalette?,
        foregroundPalette: AppForegroundPalette?,
        artworkIdentity: String,
        checksum: UInt64,
        scheme: ColorScheme? = nil
    ) {
        let currentScheme = scheme ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
        guard artworkIdentity != lastHeaderColorIdentity || checksum != lastHeaderColorChecksum || currentScheme != lastHeaderColorScheme else {
            return
        }
        let token = FirstUseHitchDiagnostics.begin(
            "PlaylistPageController.headerColorCommit",
            detail: "identity=\(artworkIdentity.prefix(8)), checksum=\(String(checksum, radix: 16)), scheme=\(currentScheme)"
        )
        headerAccentColor = accent
        headerSemanticPalette = palette
        headerForegroundPalette = foregroundPalette ?? palette?.appForeground
        isHeaderColorReady = true
        lastHeaderColorIdentity = artworkIdentity
        lastHeaderColorChecksum = checksum
        lastHeaderColorScheme = currentScheme
        FirstUseHitchDiagnostics.end(token)
    }

    private func noteHeaderColorDiscard(reason: String, artworkIdentity: String) {
        let token = FirstUseHitchDiagnostics.begin(
            "PlaylistPageController.headerColorDedupDiscard",
            detail: "reason=\(reason), identity=\(artworkIdentity.prefix(8))"
        )
        FirstUseHitchDiagnostics.end(token)
    }

    private func startImmediateHaloSeedLoad(
        payload: HeaderArtworkPayload,
        artworkIdentity: String,
        selectionIdentity: String,
        resolveToken: UUID
    ) {
        headerHaloSeedTask?.cancel()
        let request = PlaylistArtworkPipeline.haloSeedRequest(
            artworkIdentity: artworkIdentity,
            artworkData: payload.data,
            fileURL: payload.fileURL,
            pixelSide: FadeTiming.haloSeedPixelSide
        )

        headerHaloSeedTask = Task { @MainActor in
            guard let pipeline = self.playlistArtworkPipeline else { return }
            let seed = await pipeline.load(request)
            guard !Task.isCancelled else { return }
            guard self.headerResolveToken == resolveToken else { return }
            guard self.page?.selectionIdentity == selectionIdentity else { return }
            self.publishHaloImage(seed, identity: artworkIdentity, resolveToken: resolveToken)
        }
    }

    private func startArtworkPrefetch(
        key: String,
        requests: [PlaylistArtworkRequest],
        priority: TaskPriority = .background
    ) {
        guard !requests.isEmpty, !prefetchedArtworkKeys.contains(key) else { return }
        prefetchedArtworkKeys.insert(key)

        if artworkPrefetchTasks.count >= 6, let oldestKey = artworkPrefetchTasks.keys.first {
            artworkPrefetchTasks[oldestKey]?.cancel()
            artworkPrefetchTasks.removeValue(forKey: oldestKey)
        }

        guard let pipeline = playlistArtworkPipeline,
              let task = pipeline.prefetch(requests, priority: priority) else { return }
        artworkPrefetchTasks[key] = task

        Task { @MainActor in
            await task.value
            self.artworkPrefetchTasks.removeValue(forKey: key)
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
        headerHaloSeedTask?.cancel()
        headerLoadDispatchTask?.cancel()
        headerColorTask?.cancel()
        headerColorExtractor?.cancelPending()
        headerCurrentArtwork = nil
        headerIncomingArtwork = nil
        headerIncomingOpacity = 0
        haloCurrentImage = nil
        haloIncomingImage = nil
        haloSourceBlendOpacity = 1
        haloPresentationOpacity = 0
        if let identity,
           let cached = headerColorExtractor?.cachedResult(artworkIdentity: identity)
        {
            headerAccentColor = cached.accent
            headerSemanticPalette = cached.palette
            headerForegroundPalette = cached.foreground ?? cached.palette?.appForeground
            isHeaderColorReady = headerForegroundPalette != nil || headerSemanticPalette != nil
            lastHeaderColorIdentity = identity
            lastHeaderColorChecksum = cached.checksum
            lastHeaderColorScheme = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        } else {
            headerAccentColor = ThemeStore.shared.accentColor
            headerSemanticPalette = nil
            headerForegroundPalette = nil
            isHeaderColorReady = false
            lastHeaderColorIdentity = nil
            lastHeaderColorChecksum = 0
            lastHeaderColorScheme = nil
        }
        lastHeaderArtworkData = nil
        inFlightHeaderColorRequestKey = nil
    }

    func colorSchemeDidChange(to scheme: ColorScheme) {
        guard let identity = lastHeaderColorIdentity else { return }
        guard scheme != lastHeaderColorScheme else { return }

        let isDark = (scheme == .dark)
        if let cached = headerColorExtractor?.cachedResult(artworkIdentity: identity, isDark: isDark) {
            commitHeaderColor(
                accent: cached.accent,
                palette: cached.palette,
                foregroundPalette: cached.foreground,
                artworkIdentity: identity,
                checksum: cached.checksum,
                scheme: scheme
            )
        } else if let data = lastHeaderArtworkData {
            let resolveToken = UUID()
            self.headerResolveToken = resolveToken
            isHeaderColorReady = false

            headerColorTask?.cancel()
            guard let headerColorExtractor else { return }
            headerColorTask = Task(priority: .utility) { @MainActor in
                let result = await headerColorExtractor.extract(
                    from: data,
                    artworkIdentity: identity,
                    isDark: isDark
                )
                guard !Task.isCancelled else { return }
                guard self.headerResolveToken == resolveToken else { return }
                if let result {
                    self.commitHeaderColor(
                        accent: result.accent,
                        palette: result.palette,
                        foregroundPalette: result.palette.appForeground,
                        artworkIdentity: identity,
                        checksum: self.lastHeaderColorChecksum,
                        scheme: scheme
                    )
                }
            }
        } else {
            isHeaderColorReady = headerForegroundPalette != nil || headerSemanticPalette != nil
        }
    }

    private func publishHeaderImage(_ image: NSImage, identity: String, resolveToken: UUID) {
        guard currentArtworkPresentationIdentity == identity else { return }
        guard headerResolveToken == resolveToken else { return }
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
        guard headerResolveToken == resolveToken else { return }
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
            guard self.headerResolveToken == resolveToken else { return }

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

    private func headerArtworkPayload(
        request: DetailHeaderArtworkRequest,
        resolved: ResolvedHeaderArtwork?
    ) -> HeaderArtworkPayload {
        switch request {
        case .playlist:
            if let fileURL = resolved?.fileURL {
                return HeaderArtworkPayload(data: nil, fileURL: fileURL)
            }
            return HeaderArtworkPayload(
                data: resolved?.image?.tiffRepresentation,
                fileURL: resolved?.fileURL
            )
        case .artist(_, let entry, _):
            // Use saved data first, then any resolved image (including the
            // placeholder mosaic). Placeholder is a real track-collage image,
            // so it's a valid halo seed — without this the halo never loads
            // for artists that have no persisted artworkData.
            return HeaderArtworkPayload(
                data: entry.artworkData ?? resolved?.image?.tiffRepresentation,
                fileURL: resolved?.fileURL
            )
        case .album(_, let entry, let fallbackImage):
            let squareData: Data? = {
                switch resolved?.source {
                case .custom, .albumFallback:
                    return resolved?.image?.tiffRepresentation
                default:
                    return nil
                }
            }()
            return HeaderArtworkPayload(
                data: squareData ?? fallbackImage?.tiffRepresentation ?? resolved?.image?.tiffRepresentation ?? entry.artworkData,
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
        case .home, .allSongs, .allPlaylists, .allAlbums, .allArtists:
            config = nil
        case .playlist(let id):
            guard let playlist = libraryVM.playlists.first(where: { $0.id == id }) else { return nil }
            config = .playlist(
                playlist,
                entry: PlaylistHeaderData(
                    description: playlist.userDescription,
                    tracks: displayedTracks,
                    artworkRevision: libraryVM.playlistArtworkRevision(playlistID: playlist.id)
                )
            )
        case .artist(let key):
            guard let entry = libraryVM.artistEntries.first(where: { $0.canonicalName == key }) else {
                return nil
            }
            let albumCount = Set(displayedTracks.map(\.albumGroupKey)).count
            config = .artist(
                entry,
                stats: ArtistDerivedStats(
                    trackCount: displayedTracks.count,
                    albumCount: albumCount,
                    totalDuration: displayedTotalDuration,
                    artworkTracks: displayedTracks
                )
            )
        case .album(let key):
            guard let entry = libraryVM.albumEntries.first(where: { $0.canonicalKey == key }) else {
                return nil
            }
            let fallbackArtwork = displayedTracks.first?.artworkData.flatMap {
                ArtworkLoader.squareHeaderPreviewImage(data: $0, maxPixelSize: 320)
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

    @discardableResult
    private func revealPendingTrackIfPossible() -> Bool {
        guard let targetID = pendingRevealTrackID else { return false }
        guard let page else { return false }

        guard page.rows.contains(where: { $0.id == targetID }) else {
            return false
        }

        pendingRevealTrackID = nil
        isRevealScrollArmed = true
        scheduleRevealScroll(for: targetID, animated: pendingRevealAnimated)
        scheduleSnapshotUpdate()
        return true
    }

    /// Scroll to the reveal target. The short stabilization delay is essential
    /// for the cross-playlist case: `applyPageModel` runs in the same transaction
    /// that swaps the ProgressView for a freshly-created ScrollView, and a
    /// brand-new ScrollView with a LazyVStack does not reliably honor an initial
    /// `scrollPosition` binding (the target row may not be realized yet, and the
    /// binding's setter can fire with nil/first-row, clobbering the target). By
    /// deferring the position change to after the scroll view exists, the change
    /// becomes a normal animated state update on an existing view.
    private func scheduleRevealScroll(for trackID: UUID, animated: Bool) {
        revealScrollTask?.cancel()
        let delay = RevealScroll.scrollStabilizationDelayMilliseconds
        revealScrollTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            guard let self else { return }

            if animated {
                withAnimation(RevealScroll.animation) {
                    self.listScrollPositionID = trackID
                }
                self.scheduleRevealHighlight(for: trackID)
            } else {
                self.listScrollPositionID = trackID
                self.isRevealScrollArmed = false
            }
        }
    }

    /// Fire the reveal-highlight pulse after the scroll animation settles, and
    /// release the scroll-position guard.
    private func scheduleRevealHighlight(for trackID: UUID) {
        revealHighlightTask?.cancel()
        revealHighlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(RevealScroll.highlightDelayMilliseconds))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.isRevealScrollArmed = false
            self.revealHighlightTrackID = trackID
        }
    }

    /// Called by the row view after its highlight animation ends.
    func clearRevealHighlight(for trackID: UUID) {
        if revealHighlightTrackID == trackID {
            revealHighlightTrackID = nil
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
        case .allPlaylists, .allAlbums, .allArtists:
            return []
            // Missing (source file deleted) tracks stay visible as greyed,
            // non-playable rows so the user can delete them manually; only
            // playback/history/recommendation flows filter them out.
        case .home:
            return libraryVM.allTracks
        case .allSongs:
            return libraryVM.allTracks
        case .playlist(let id):
            return libraryVM.playlists.first(where: { $0.id == id })?.tracks ?? []
        case .artist(let key):
            return libraryVM.allTracks.filter {
                LibraryNormalization.containsArtist(key, in: $0.artist)
            }
        case .album(let key):
            return libraryVM.allTracks.filter {
                $0.albumGroupKey == key
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
        selection.selectionIdentity(in: libraryVM)
    }

    private func searchHits(
        for searchText: String,
        displayedTrackIDs: [UUID],
        libraryVM: LibraryViewModel
    ) async -> [UUID: LibrarySearchHit] {
        let scope = Set(displayedTrackIDs)
        guard !scope.isEmpty else { return [:] }
        let limit = max(100, min(2_000, scope.count))
        return await libraryVM.searchTracks(
            query: searchText,
            scopedTo: scope,
            limit: limit
        )
    }

    private static func buildPageResult(
        displayedTracks: [PageTrackSource],
        entries: [SortableTrackEntry],
        searchText: String,
        searchHits: [UUID: LibrarySearchHit],
        sortKey: TrackSortKey,
        sortOrder: TrackSortOrder,
        customOrderIDs: [UUID]?
    ) async -> BuildResult {
        await Task.detached(priority: .userInitiated) {
            let filteredEntries: [SortableTrackEntry]
            if searchText.isEmpty {
                filteredEntries = entries
            } else {
                filteredEntries = entries.filter {
                    searchHits[$0.id] != nil
                }
            }

            let sourceIndex = Dictionary(uniqueKeysWithValues: entries.enumerated().map {
                ($0.element.id, $0.offset)
            })
            let customRank = customOrderIDs.map { orderIDs in
                Dictionary(uniqueKeysWithValues: orderIDs.enumerated().map {
                    ($0.element, $0.offset)
                })
            }
            let customComparator: (SortableTrackEntry, SortableTrackEntry) -> Bool = { lhs, rhs in
                guard let customRank else {
                    return (sourceIndex[lhs.id] ?? Int.max) < (sourceIndex[rhs.id] ?? Int.max)
                }

                let lhsRank = customRank[lhs.id]
                let rhsRank = customRank[rhs.id]
                switch (lhsRank, rhsRank) {
                case let (lhs?, rhs?):
                    if lhs != rhs { return lhs < rhs }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                let lhsSource = sourceIndex[lhs.id] ?? Int.max
                let rhsSource = sourceIndex[rhs.id] ?? Int.max
                if lhsSource != rhsSource {
                    return lhsSource < rhsSource
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }

            let sortedFiltered = filteredEntries.sorted { lhs, rhs in
                if !searchText.isEmpty,
                   let lhsHit = searchHits[lhs.id],
                   let rhsHit = searchHits[rhs.id],
                   abs(lhsHit.score - rhsHit.score) > 0.000_1 {
                    return lhsHit.score > rhsHit.score
                }
                if sortKey == .custom {
                    return customComparator(lhs, rhs)
                }
                return compareSortableTracks(lhs, rhs, sortKey: sortKey, sortOrder: sortOrder)
            }
            let queueEntries = searchText.isEmpty
                ? sortedFiltered
                : entries.sorted {
                    if sortKey == .custom {
                        return customComparator($0, $1)
                    }
                    return compareSortableTracks($0, $1, sortKey: sortKey, sortOrder: sortOrder)
                }

            let displayedTrackByID = Dictionary(uniqueKeysWithValues: displayedTracks.map { ($0.id, $0) })
            let rowRecords = sortedFiltered.compactMap { entry -> PlaylistPageRowRecord? in
                guard let track = displayedTrackByID[entry.id] else { return nil }
                let artworkFileURL = resolvedArtworkURL(for: track)
                return PlaylistPageRowRecord(
                    id: track.id,
                    title: track.title,
                    artist: track.artist,
                    lyricSnippetLine: searchHits[track.id]?.lyricSnippetLine,
                    lyricSnippetStartTime: searchHits[track.id]?.lyricSnippetStartTime,
                    lyricHighlightRanges: searchHits[track.id]?.lyricHighlightRanges ?? [],
                    durationText: formatDuration(track.duration),
                    artworkIdentity: PlaylistArtworkPipeline.rowSourceIdentity(
                        trackID: track.id,
                        artworkData: track.artworkData,
                        artworkFileURL: artworkFileURL
                    ),
                    artworkFileURL: artworkFileURL,
                    isMissing: track.isMissing
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

    private nonisolated static func resolvedArtworkURL(for track: PageTrackSource) -> URL? {
        guard !track.libraryRootSnapshot.isEmpty else { return nil }
        let paths = LibraryPaths(
            rootURL: URL(
                fileURLWithPath: track.libraryRootSnapshot,
                isDirectory: true
            )
        )

        let fileManager = FileManager.default
        for fileName in paths.trackArtworkCandidateFileNames(
            preferredFileName: track.artworkFileName
        ) {
            guard let url = paths.trackArtworkURL(
                for: track.id,
                fileName: fileName
            ) else { continue }
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        guard let artworkFileName = track.artworkFileName,
              !artworkFileName.isEmpty
        else { return nil }
        return paths.trackArtworkURL(for: track.id, fileName: artworkFileName)
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
        case .custom:
            return false
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


    private nonisolated static func formatDuration(_ duration: Double) -> String {
        guard duration.isFinite, duration > 0 else { return "0:00" }
        let totalSeconds = Int(duration.rounded(.down))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
