//
//  PlaylistDetailView.swift
//  myPlayer2
//
//  kmgccc_player - Playlist Detail View
//  Displays tracks in a playlist or all songs.
//
//  Import button is HERE (per-playlist), NOT in main toolbar.
//

import AppKit
import SwiftUI

// MARK: - Halo Session State (Parent-Owned)

/// Parent-owned halo session state that persists independently of header view lifecycle.
/// The header may report geometry upward, but this state survives header recycling/offscreen.
/// Missing/nil child updates NEVER destroy the current valid state.
///
/// Transform model:
/// - Position: halo moves upward with scroll but at a damped rate (slower than cover)
/// - Scale: starts small (baseScale) and grows gradually via an eased curve
/// - No withAnimation on the scroll path — transforms are computed directly
///   from the raw scroll delta, keeping the per-frame cost minimal.
@MainActor
@Observable
final class HaloSessionState {
    /// Identity of the selection this session belongs to
    var selectionIdentity: String?

    /// Resolved artwork image for the current selection (same source as header)
    var resolvedArtwork: NSImage?

    /// Last valid cover anchor center in scroll-content coordinate space
    /// Set when header reports valid bounds; persists after header scrolls offscreen.
    /// NOT cleared on selection change — reused for immediate first paint.
    var lastValidAnchor: CGPoint?

    /// Raw scroll delta from initial offset. Written once per scroll frame.
    /// All derived transforms (position, scale) are computed inline from this single value.
    private(set) var scrollDelta: CGFloat = 0

    /// Initial scroll offset captured on first measurement after session start.
    private var initialScrollOffset: CGFloat?

    // MARK: - Transform constants

    /// Desired halo speed as a fraction of scroll-content speed (screen space).
    /// 0.6 = halo moves upward at 60 % of the speed the cover/content moves.
    ///
    /// The halo is embedded inside the scroll content, so it already inherits
    /// a 1:1 scroll movement. To achieve fraction f in screen space the halo's
    /// position within content must be counteracted by (1 - f) of each scroll
    /// unit. See `contentSpaceOffset`.
    private static let parallaxFraction: CGFloat = 0.6

    /// Resting scale before any scroll
    private static let baseScale: CGFloat = 0.72

    /// Maximum additional scale growth at full scroll extent
    private static let maxScaleGrowth: CGFloat = 0.5

    /// Scroll distance (pts) over which scale grows from base to base+max
    private static let scaleRange: CGFloat = 500

    // MARK: - Derived transforms

    /// Whether this session has valid content to render
    var hasValidContent: Bool {
        resolvedArtwork != nil && lastValidAnchor != nil
    }

    /// Y offset to apply in VStack-content space to achieve the parallax effect.
    ///
    /// Because the halo lives inside the scroll content it already moves with
    /// the list at 1:1. To make it appear slower (at `parallaxFraction` of
    /// scroll speed) we partially counteract the scroll in content space:
    ///
    ///   contentSpaceOffset = scrollDelta × (f − 1)
    ///
    /// Derivation (scroll down by N, scrollDelta = −N):
    ///   • content moves up N in screen space
    ///   • halo content-Y += (−N)(f − 1) = N(1 − f)
    ///   • halo screen-Y  = content-Y − N = +N(1−f) − N = −Nf   ✓
    ///   • cover screen-Y = −N  →  halo (−Nf) < cover (−N)  ✓
    var contentSpaceOffset: CGFloat {
        scrollDelta * (Self.parallaxFraction - 1.0)
    }

    /// Scale computed from scroll distance via an ease-out power curve.
    /// Grows gradually as the user scrolls upward; stays at baseScale at rest.
    var computedScale: CGFloat {
        let upwardScroll = max(0, -scrollDelta)
        let t = min(upwardScroll / Self.scaleRange, 1.0)
        // ease-out: fast initial growth that tapers off
        let eased = 1.0 - pow(1.0 - t, 2.5)
        return Self.baseScale + Self.maxScaleGrowth * eased
    }

    // MARK: - Mutations

    /// Start a new session for a different selection.
    /// Preserves lastValidAnchor for immediate first paint (anchor updates naturally
    /// from the next geometry report). Does NOT clear artwork — prevents white flash.
    func beginNewSession(selectionIdentity: String) {
        self.selectionIdentity = selectionIdentity
        // lastValidAnchor deliberately kept — same header position, enables instant halo
        // resolvedArtwork deliberately kept — prevents flash on transition
        self.initialScrollOffset = nil
        self.scrollDelta = 0
    }

    /// Update artwork when a valid new resolution arrives.
    /// Only replaces if the identity matches the current session.
    func updateArtwork(identity: String, image: NSImage?) {
        guard self.selectionIdentity == identity else { return }
        self.resolvedArtwork = image
    }

    /// Update anchor from header geometry report.
    /// Only accepts valid bounds; nil values are ignored (never destroy current state).
    func updateAnchorIfValid(bounds: CGRect?) {
        guard let bounds, bounds.width > 0, bounds.height > 0 else { return }
        self.lastValidAnchor = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Update scroll delta from current offset. Called once per scroll frame.
    /// No animation, no threshold — just a single property write.
    func updateScroll(offset: CGFloat) {
        if initialScrollOffset == nil {
            initialScrollOffset = offset
        }
        scrollDelta = offset - (initialScrollOffset ?? offset)
    }
}

// MARK: - Halo Render View (isolated observation boundary)

/// Standalone View struct that renders the halo bloom.
///
/// Being a separate struct creates an independent @Observable tracking boundary:
/// SwiftUI only re-evaluates *this* body when `session.scrollDelta` changes —
/// not `PlaylistDetailView.body` and not the LazyVStack track list.
/// Without this isolation, every scroll frame would re-diff the entire content
/// tree (track rows, header, preference keys), causing jank on long playlists.
fileprivate struct HaloRenderView: View {
    let session: HaloSessionState

    var body: some View {
        Group {
            if session.hasValidContent,
               let image = session.resolvedArtwork,
               let anchor = session.lastValidAnchor
            {
                let bloomSize: CGFloat = 220 * 4.0
                let haloX = anchor.x
                // contentSpaceOffset counteracts (1 - parallaxFraction) of scroll
                // so the halo drifts slower than the cover in screen space.
                let haloY = anchor.y + session.contentSpaceOffset

                BlurredArtworkBackgroundView(image: image, bloomSize: bloomSize)
                    .frame(width: bloomSize, height: bloomSize * 1.5)
                    .scaleEffect(session.computedScale)
                    .position(x: haloX, y: haloY)
            }
        }
        .frame(height: 0)          // takes no layout space
        .allowsHitTesting(false)
    }
}

// MARK: - Playlist Detail View

/// View displaying tracks in the selected playlist or all songs.
struct PlaylistDetailView<HeaderAccessory: View>: View {

    private struct BatchEditRequest: Identifiable {
        let id = UUID()
        let tracks: [Track]
    }

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(\.colorScheme) private var colorScheme

    private let headerAccessory: HeaderAccessory

    // MARK: - State

    @State private var trackToEdit: Track?
    @State private var searchText: String = ""
    @State private var listScrollPositionID: UUID?
    @State private var displayedTracksCache: [Track] = []
    @State private var filteredTracksCache: [Track] = []
    @State private var sortedTracksCache: [Track] = []
    @State private var parentSortedTracksCache: [Track] = []
    @State private var viewSnapshot: PlaylistViewSnapshot = .empty
    @State private var sortedTrackIndexMapCache: [UUID: Int] = [:]
    @State private var parentSortedTrackIndexMapCache: [UUID: Int] = [:]
    @State private var trackByIDCache: [UUID: Track] = [:]
    @State private var prefetchTask: Task<Void, Never>?
    @State private var rebuildTask: Task<Void, Never>?
    @State private var snapshotUpdateTask: Task<Void, Never>?
    @State private var activeRebuildToken = UUID()
    @State private var isRebuilding = false
    @State private var lastQueueTrackIDs: [UUID] = []
    @State private var lastPrefetchBucket: Int?
    @FocusState private var isSearchFocused: Bool
    @State private var isMultiselectMode = false
    @State private var selectedTrackIDs: Set<UUID> = []
    @State private var sortSymbolEffectTrigger = 0
    @State private var batchEditRequest: BatchEditRequest?

    /// Parent-owned halo session state - survives header lifecycle, selection switches
    @State private var haloSession = HaloSessionState()

    // MARK: - Init

    init(
        @ViewBuilder headerAccessory: () -> HeaderAccessory = { EmptyView() }
    ) {
        self.headerAccessory = headerAccessory()
    }

    var body: some View {
        Group {
            if libraryVM.currentSelection == .allSongs {
                if libraryVM.state == .loading
                    || (isRebuilding && displayedTracksCache.isEmpty && viewSnapshot.isEmpty)
                {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayedTracksCache.isEmpty {
                    emptyStateView
                } else if filteredTracksCache.isEmpty {
                    noResultsView
                } else {
                    trackListView
                }
            } else {
                detailScrollView
            }
        }
        // Fill available space, anchor content to top
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Overlay toolbar at top - reads width from parent's frame constraint
        .overlay(alignment: .topLeading) {
            GeometryReader { overlayGeo in
                ZStack(alignment: .topLeading) {
                    // Decorative fade background - can extend left, doesn't affect toolbar layout
                    playlistTopFade(width: overlayGeo.size.width)
                        .offset(x: -48)
                        .allowsHitTesting(false)

                    // Toolbar content row - strictly constrained to content width
                    headerViewInternal(width: overlayGeo.size.width)
                        .ignoresSafeArea(.container, edges: .top)
                }
            }
            .frame(height: GlassStyleTokens.headerBarHeight + 8)
        }
        .frame(minWidth: 320)
        .sheet(item: $trackToEdit) { track in
            TrackEditSheet(track: track)
        }
        .sheet(
            item: $batchEditRequest,
            onDismiss: {
                clearMultiselectState()
            }
        ) { request in
            BatchTrackEditSheet(
                tracks: request.tracks
            )
            .presentationSizing(.page)
        }
        .onAppear {
            scheduleRebuild(reason: "appear", restoreScroll: true)
        }
        .onDisappear {
            prefetchTask?.cancel()
            prefetchTask = nil
            rebuildTask?.cancel()
            rebuildTask = nil
            snapshotUpdateTask?.cancel()
            snapshotUpdateTask = nil
            Task {
                await LibraryTrackSnapshotBuilder.shared.cancelBuild()
            }
        }
        .onChange(of: libraryVM.selectedPlaylist?.id) { oldVal, newVal in
            // Begin new halo session for different playlist - preserves old artwork until new resolves
            haloSession.beginNewSession(selectionIdentity: "playlist-\(newVal ?? UUID())")
            scheduleRebuild(reason: "playlist", restoreScroll: true)
        }
        .onChange(of: libraryVM.selectedArtistKey) { oldVal, newVal in
            // Begin new halo session for different artist
            haloSession.beginNewSession(selectionIdentity: "artist-\(newVal ?? "")")
            scheduleRebuild(reason: "artist", restoreScroll: true)
        }
        .onChange(of: libraryVM.selectedAlbumKey) { oldVal, newVal in
            // Begin new halo session for different album
            haloSession.beginNewSession(selectionIdentity: "album-\(newVal ?? "")")
            scheduleRebuild(reason: "album", restoreScroll: true)
        }
        .onChange(of: searchText) { _, _ in
            scheduleRebuild(reason: "search", debounceNanoseconds: 150_000_000)
        }
        .onChange(of: libraryVM.trackSortKey) { _, _ in
            sortSymbolEffectTrigger += 1
            scheduleRebuild(reason: "sortKey")
        }
        .onChange(of: libraryVM.trackSortOrder) { _, _ in
            sortSymbolEffectTrigger += 1
            scheduleRebuild(reason: "sortOrder")
        }
        .onChange(of: libraryVM.totalTrackCount) { oldVal, newVal in
            scheduleRebuild(reason: "trackCount", restoreScroll: true)
        }
        .onChange(of: libraryVM.refreshTrigger) { _, _ in
            scheduleRebuild(reason: "refresh", restoreScroll: true)
        }
        .onChange(of: libraryVM.searchResetTrigger) { _, _ in
            searchText = ""
            isSearchFocused = false
        }
        .onChange(of: libraryVM.state) { oldVal, newVal in
            if newVal == .loaded {
                scheduleRebuild(reason: "state_loaded", restoreScroll: true)
            }
        }
        .onChange(of: libraryVM.currentSelection) { oldVal, newVal in
            scheduleRebuild(reason: "selection", restoreScroll: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryTrackDidUpdate)) { notification in
            guard let trackID = notification.userInfo?["trackID"] as? UUID else { return }
            applyTargetedTrackRefresh(trackID: trackID)
        }
    }

    // MARK: - Computed Properties

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Detail Header

    /// Config for LibraryDetailHeaderView. Nil for .allSongs (no header).
    private var detailHeaderConfig: DetailHeaderConfig? {
        switch libraryVM.currentSelection {
        case .allSongs:
            return nil
        case .playlist(let id):
            guard let playlist = libraryVM.playlists.first(where: { $0.id == id }) else {
                return nil
            }
            let playlistTracks = playlist.tracks.filter { $0.availability != .missing }
            return .playlist(
                playlist,
                entry: PlaylistHeaderData(
                    description: playlist.userDescription,
                    tracks: playlistTracks
                )
            )
        case .artist(let key):
            guard let entry = libraryVM.artistEntries.first(where: { $0.canonicalName == key }) else {
                return nil
            }
            let albumCount = libraryVM.albumEntries
                .filter { $0.primaryArtistCanonicalName == key }
                .count
            let totalDuration = displayedTracksCache.reduce(0) { $0 + $1.duration }
            return .artist(
                entry,
                stats: ArtistDerivedStats(
                    trackCount: displayedTracksCache.count,
                    albumCount: albumCount,
                    totalDuration: totalDuration
                )
            )
        case .album(let key):
            guard let entry = libraryVM.albumEntries.first(where: { $0.canonicalKey == key }) else {
                return nil
            }
            let totalDuration = displayedTracksCache.reduce(0) { $0 + $1.duration }
            let firstArtworkData = entry.artworkData ?? displayedTracksCache.first?.artworkData
            let firstArtwork = firstArtworkData.flatMap {
                NSImage(data: $0)
            }
            return .album(
                entry,
                stats: AlbumDerivedStats(
                    artistName: entry.primaryArtistDisplayName,
                    trackCount: displayedTracksCache.count,
                    totalDuration: totalDuration,
                    artworkImage: firstArtwork
                )
            )
        }
    }

    // MARK: - Subviews

    private func headerViewInternal(width: CGFloat) -> some View {
        HStack(spacing: 12) {
            sortMenu

            GlassToolbarTriplePill(
                isMultiselectActive: isMultiselectMode,
                onToggleMultiselect: {
                    isMultiselectMode.toggle()
                    if !isMultiselectMode {
                        selectedTrackIDs.removeAll()
                    }
                },
                canPlay: !sortedTracksCache.isEmpty,
                onPlay: {
                    if isMultiselectMode && !selectedTrackIDs.isEmpty {
                        let selected = sortedTracksCache.filter {
                            selectedTrackIDs.contains($0.id)
                        }
                        playerVM.playTracks(selected)
                    } else {
                        guard !sortedTracksCache.isEmpty else { return }
                        playerVM.playTracks(sortedTracksCache)
                    }
                },
                onImport: {
                    Task {
                        await libraryVM.importToCurrentPlaylist()
                    }
                }
            )

            Spacer(minLength: 0)

            GlassToolbarSearchField(
                placeholder: "搜索",
                text: $searchText,
                focused: $isSearchFocused
            ) {
                searchText = ""
            }
            .frame(minWidth: 96, idealWidth: 140, maxWidth: 140)

            headerAccessory
        }
        // Padding inward, then constrain to exact width - HStack naturally gets (width - padding*2)
        .padding(.horizontal, GlassStyleTokens.headerHorizontalPadding)
        .frame(width: width, height: GlassStyleTokens.headerBarHeight)
    }

    private func playlistTopFade(width: CGFloat) -> some View {
        let fadeHeight: CGFloat = GlassStyleTokens.headerBarHeight + 8
        let bg = Color(nsColor: .windowBackgroundColor)

        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Material.ultraThin)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .clear, location: colorScheme == .dark ? 0.74 : 0.82),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .mask {
                    playlistTopFadeHorizontalMask
                }

            Rectangle()
                .fill(playlistTopFadeScrimGradient(bg: bg))
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .clear, location: colorScheme == .dark ? 0.68 : 0.62),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .mask {
                    playlistTopFadeHorizontalMask
                }
        }
        .frame(width: width + 48, height: fadeHeight)
        .frame(maxWidth: .infinity, maxHeight: fadeHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var playlistTopFadeHorizontalMask: some View {
        HStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(0.15), location: 0.35),
                    .init(color: .black.opacity(0.45), location: 0.55),
                    .init(color: .black, location: 1.0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 48)
            Rectangle()
        }
    }

    private func playlistTopFadeScrimGradient(bg: Color) -> LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                stops: [
                    .init(color: bg.opacity(0.012), location: 0.0),
                    .init(color: bg.opacity(0.006), location: 0.35),
                    .init(color: bg.opacity(0.002), location: 0.60),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            stops: [
                .init(color: bg.opacity(0.40), location: 0.0),
                .init(color: bg.opacity(0.18), location: 0.30),
                .init(color: bg.opacity(0.06), location: 0.56),
                .init(color: .clear, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var sortMenu: some View {
        GlassToolbarMenuButton(
            systemImage: "arrow.up.arrow.down",
            help: "sort.help",
            style: .standard
        ) {
            Section("sort.by") {
                ForEach(TrackSortKey.allCases) { key in
                    Button {
                        libraryVM.trackSortKey = key
                    } label: {
                        if libraryVM.trackSortKey == key {
                            Label(key.title, systemImage: "checkmark")
                        } else {
                            Text(key.title)
                        }
                    }
                }
            }

            Section("sort.order") {
                ForEach(TrackSortOrder.allCases) { order in
                    Button {
                        libraryVM.trackSortOrder = order
                    } label: {
                        if libraryVM.trackSortOrder == order {
                            Label(order.title, systemImage: "checkmark")
                        } else {
                            Text(order.title)
                        }
                    }
                }
            }
        }
        .symbolEffect(.bounce, value: sortSymbolEffectTrigger)
        .simultaneousGesture(
            TapGesture().onEnded {
                sortSymbolEffectTrigger += 1
            }
        )
    }

    /// The track rows and bottom spacer shared by both scroll view variants.
    @ViewBuilder
    private var trackRowsContent: some View {
        ForEach(viewSnapshot.trackIDs, id: \.self) { trackID in
            if
                let rowSnapshot = viewSnapshot.snapshot(for: trackID),
                let track = trackByIDCache[trackID]
            {
                TrackRowView(
                    model: trackRowModel(for: rowSnapshot),
                    isPlaying: playerVM.currentTrack?.id == trackID,
                    isSelected: isMultiselectMode && selectedTrackIDs.contains(trackID),
                    onTap: {
                        if isMultiselectMode {
                            if selectedTrackIDs.contains(trackID) {
                                selectedTrackIDs.remove(trackID)
                            } else {
                                selectedTrackIDs.insert(trackID)
                            }
                        } else {
                            let startIndex = parentSortedTrackIndexMapCache[trackID] ?? 0
                            playerVM.playTracks(
                                parentSortedTracksCache,
                                startingAt: startIndex
                            )
                        }
                    },
                    onRowAppear: {
                        prefetchAroundTrackID(trackID)
                    }
                ) {
                    trackMenu(track: track)
                }
                .contextMenu {
                    trackMenu(track: track)
                }
            }
        }
        Color.clear.frame(height: 160)
    }

    private var trackListView: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                trackRowsContent
            }
            .scrollTargetLayout()
            .padding(.top, listTopPadding)
            .padding(.bottom, listBottomPadding)
            .padding(.horizontal)
            .transaction { tx in tx.animation = nil }
        }
        .scrollPosition(id: $listScrollPositionID, anchor: .top)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onChange(of: listScrollPositionID) { _, _ in
            scheduleSnapshotUpdate()
        }
        .onTapGesture {
            clearSearchFocus()
        }
    }

    /// Scroll view used for playlist/artist/album selections.
    /// Header is NOT inside LazyVStack - uses separate VStack for stability.
    /// Halo renders from parent-owned session state.
    private var detailScrollView: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                // Halo layer - renders from parent-owned session state
                // Independent of header view lifecycle
                haloLayer

                // Header section - NOT inside LazyVStack for stable lifecycle
                // Reports geometry upward but doesn't own halo state
                if let config = detailHeaderConfig {
                    headerContentSection(config: config)
                }

                // Track content section - uses LazyVStack for performance
                trackContentSection
            }
            .padding(.top, listTopPadding)
            .padding(.bottom, listBottomPadding)
            .padding(.horizontal)
            .transaction { tx in tx.animation = nil }
        }
        .coordinateSpace(name: "detailScroll")
        .scrollPosition(id: $listScrollPositionID, anchor: .top)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onChange(of: listScrollPositionID) { _, _ in
            scheduleSnapshotUpdate()
        }
        .onTapGesture {
            clearSearchFocus()
        }
    }

    /// Halo layer — hosts HaloRenderView and attaches the scroll-offset sensor.
    ///
    /// Rendering is delegated to HaloRenderView (a separate View struct) so that
    /// @Observable tracking for per-frame scrollDelta changes is scoped to that
    /// tiny view. This view just owns the preference sensor and the write path.
    private var haloLayer: some View {
        HaloRenderView(session: haloSession)
            // Scroll-offset sensor: measures haloLayer's Y in the ScrollView's
            // fixed coordinate space. Value decreases as content scrolls up.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: geo.frame(in: .named("detailScroll")).minY
                        )
                }
            )
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                haloSession.updateScroll(offset: offset)
            }
    }

    /// Header content section - positioned outside LazyVStack for stable lifecycle.
    /// Reports geometry to parent but doesn't own halo state.
    @ViewBuilder
    private func headerContentSection(config: DetailHeaderConfig) -> some View {
        LibraryDetailHeaderView(
            config: config,
            onPlay: {
                guard !sortedTracksCache.isEmpty else { return }
                playerVM.playTracks(sortedTracksCache)
            },
            canPlay: !sortedTracksCache.isEmpty
        )
        .onPreferenceChange(HeaderArtworkBoundsPreferenceKey.self) { bounds in
            // CRITICAL: Only accept valid bounds - never destroy state on nil
            // This prevents halo disappearing when header scrolls offscreen
            haloSession.updateAnchorIfValid(bounds: bounds)
        }
        .onPreferenceChange(HeaderArtworkImagePreferenceKey.self) { image in
            // Update artwork in session - only if valid image provided
            if let image {
                haloSession.updateArtwork(
                    identity: haloSession.selectionIdentity ?? "",
                    image: image
                )
            }
        }

        Spacer().frame(height: 12)
    }

    /// Track content section - uses LazyVStack for performance.
    private var trackContentSection: some View {
        Group {
            if libraryVM.state == .loading
                || (isRebuilding && displayedTracksCache.isEmpty && viewSnapshot.isEmpty)
            {
                ProgressView()
                    .controlSize(.large)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else if filteredTracksCache.isEmpty
                && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("library.no_results")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            } else {
                trackRowsContent
                    .padding(.horizontal, 16)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("library.no_songs")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("library.import_desc")
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            // Import button in empty state
            Button {
                print("🔘 Import button (empty state) tapped")
                Task {
                    await libraryVM.importToCurrentPlaylist()
                }
            } label: {
                Label(
                    "library.import_btn",
                    systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture { clearSearchFocus() }
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            Text("library.no_results")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(String(format: NSLocalizedString("library.no_matches", comment: ""), searchText))
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture { clearSearchFocus() }
    }

    private var songCountText: String {
        if isFiltering {
            return String(
                format: NSLocalizedString("library.song_count_filtered", comment: ""),
                filteredTracksCache.count, displayedTracksCache.count)
        }
        let format =
            displayedTracksCache.count == 1
            ? NSLocalizedString("library.song_count_one", comment: "")
            : NSLocalizedString("library.song_count", comment: "")
        return String(format: format, displayedTracksCache.count)
    }

    private var totalSelectionCount: Int {
        selectedTrackIDs.count
    }

    @ViewBuilder
    private func trackMenu(track: Track) -> some View {
        if isMultiselectMode && selectedTrackIDs.contains(track.id) {
            // Batch Actions
            Text("已选择 \(selectedTrackIDs.count) 首歌曲")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            Divider()

            Button {
                openBatchEditor()
            } label: {
                Label("批量编辑歌曲信息…", systemImage: "square.stack.3d.forward.dottedline")
            }

            Divider()

            Menu {
                ForEach(libraryVM.playlists) { playlist in
                    if libraryVM.selectedPlaylist?.id != playlist.id {
                        Button {
                            processBatchAction { tracks in
                                await libraryVM.addTracksToPlaylist(tracks, playlist: playlist)
                            }
                        } label: {
                            Label(playlist.name, systemImage: "music.note.list")
                        }
                    }
                }

                Divider()

                Button {
                    processBatchAction { tracks in
                        let playlist = await libraryVM.createNewPlaylist()
                        await libraryVM.addTracksToPlaylist(tracks, playlist: playlist)
                    }
                } label: {
                    Label("新建播放列表", systemImage: "plus")
                }
            } label: {
                Label("添加到播放列表...", systemImage: "plus.circle")
            }
            .id("batch_add_to_playlist_\(libraryVM.playlists.count)")

            if let currentPlaylist = libraryVM.selectedPlaylist {
                Button {
                    processBatchAction { tracks in
                        await libraryVM.removeTracksFromPlaylist(tracks, playlist: currentPlaylist)
                    }
                } label: {
                    Label("从当前播放列表移除", systemImage: "minus.circle")
                }
            }

            Divider()

            Button(role: .destructive) {
                processBatchAction { tracks in
                    for track in tracks {
                        await libraryVM.deleteTrack(track)
                    }
                    // Clear selection after delete
                    await MainActor.run {
                        // Selection will be cleared by cache rebuild or logic
                        selectedTrackIDs.removeAll()
                    }
                }
            } label: {
                Label("从资料库删除", systemImage: "trash")
            }

        } else {
            // SINGLE TRACK ACTIONS (Keep existing)

            // Enter multiselect mode
            Button {
                isMultiselectMode = true
                selectedTrackIDs.insert(track.id)
            } label: {
                Label("多选歌曲…", systemImage: "checkmark.circle")
            }

            Divider()

            // Play
            Button {
                let startIndex = parentSortedTrackIndexMapCache[track.id] ?? 0
                playerVM.playTracks(parentSortedTracksCache, startingAt: startIndex)
            } label: {
                Label("播放", systemImage: "play")
            }

            Divider()

            // Add to Playlist
            Menu {
                ForEach(libraryVM.playlists) { playlist in
                    // Don't show current playlist if we are in it
                    if libraryVM.selectedPlaylist?.id != playlist.id {
                        Button {
                            Task {
                                await libraryVM.addTracksToPlaylist(
                                    [track], playlist: playlist)
                            }
                        } label: {
                            Label(playlist.name, systemImage: "music.note.list")
                        }
                    }
                }

                Divider()

                Button {
                    Task {
                        let playlist = await libraryVM.createNewPlaylist()
                        await libraryVM.addTracksToPlaylist([track], playlist: playlist)
                    }
                } label: {
                    Label("新建播放列表", systemImage: "plus")
                }
            } label: {
                Label("添加到播放列表...", systemImage: "plus.circle")
            }
            .id("single_add_to_playlist_\(libraryVM.playlists.count)")

            // Remove from Playlist (if in one)
            if let currentPlaylist = libraryVM.selectedPlaylist {
                Button {
                    Task {
                        await libraryVM.removeTracksFromPlaylist(
                            [track], playlist: currentPlaylist)
                    }
                } label: {
                    Label("从当前播放列表移除", systemImage: "minus.circle")
                }
            }

            Divider()

            // Edit Metadata
            Button {
                trackToEdit = track
            } label: {
                Label("编辑歌曲信息", systemImage: "info.circle")
            }

            Divider()

            // Delete from Library
            Button(role: .destructive) {
                Task {
                    await libraryVM.deleteTrack(track)
                }
            } label: {
                Label("从资料库删除", systemImage: "trash")
            }
        }
    }

    private func processBatchAction(action: @escaping ([Track]) async -> Void) {
        let selectedTracks = sortedTracksCache.filter { selectedTrackIDs.contains($0.id) }
        Task {
            await action(selectedTracks)
            await MainActor.run {
                isMultiselectMode = false
                selectedTrackIDs.removeAll()
            }
        }
    }

    private func selectedTracksForBatchEditor() -> [Track] {
        sortedTracksCache.filter { selectedTrackIDs.contains($0.id) }
    }

    private func openBatchEditor() {
        let selectedTracks = selectedTracksForBatchEditor()
        guard !selectedTracks.isEmpty else { return }
        uiState.lyricsPanelSuppressedByModal = true
        batchEditRequest = BatchEditRequest(
            tracks: selectedTracks
        )
    }

    private func clearMultiselectState() {
        uiState.lyricsPanelSuppressedByModal = false
        isMultiselectMode = false
        selectedTrackIDs.removeAll()
    }

    private var listTopPadding: CGFloat { GlassStyleTokens.headerBarHeight + 16 }

    private var listBottomPadding: CGFloat { 16 }

    // MARK: - Header Background

private func clearSearchFocus() {
        if isSearchFocused {
            isSearchFocused = false
        }
    }

    private func restoreScrollIfNeeded() {
        let playlistID = libraryVM.selectedPlaylist?.id
        let restoreID = uiState.consumeLibraryRestoreTarget(for: playlistID)

        guard
            let restoreID,
            sortedTracksCache.contains(where: { $0.id == restoreID })
        else {
            // No restore target (or missing in current dataset): keep default initial position.
            listScrollPositionID = nil
            return
        }

        // Defer one runloop to ensure scroll container has mounted.
        Task { @MainActor in
            listScrollPositionID = restoreID
        }
    }

    private func updateLibrarySnapshot() {
        let firstID = sortedTracksCache.first?.id
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

    private func scheduleSnapshotUpdate() {
        snapshotUpdateTask?.cancel()
        snapshotUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            updateLibrarySnapshot()
        }
    }

    private func scheduleRebuild(
        reason: String,
        debounceNanoseconds: UInt64 = 0,
        restoreScroll: Bool = false
    ) {
        rebuildTask?.cancel()
        let token = UUID()
        activeRebuildToken = token
        rebuildTask = Task { @MainActor in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled else { return }
            isRebuilding = true
            await performRebuild(
                reason: reason,
                restoreScroll: restoreScroll,
                token: token
            )
        }
    }

    private func performRebuild(
        reason: String,
        restoreScroll: Bool,
        token: UUID
    ) async {
        let rebuildStart = ProcessInfo.processInfo.systemUptime
        let displayedTracks = currentDisplayedTracks()
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredTracks: [Track] = {
            guard !trimmedSearch.isEmpty else { return displayedTracks }
            return displayedTracks.filter {
                $0.title.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }()

        let sortedTracks = libraryVM.sortedTracks(filteredTracks)
        let parentSortedTracks = libraryVM.sortedTracks(displayedTracks)
        let rowScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let rowPixels = CGSize(
            width: Constants.Layout.artworkSmallSize * rowScale,
            height: Constants.Layout.artworkSmallSize * rowScale
        )
        let inputs = sortedTracks.map {
            TrackRowBuildInput(
                trackID: $0.id,
                title: $0.title,
                artist: $0.artist,
                album: $0.album,
                duration: $0.duration,
                artworkData: $0.artworkData,
                isMissing: $0.availability == .missing
            )
        }
        guard let snapshot = await LibraryTrackSnapshotBuilder.shared.buildSnapshot(
            playlistID: libraryVM.selectedPlaylist?.id ?? UUID(),
            tracks: inputs,
            targetPixelSize: rowPixels
        ) else {
            if activeRebuildToken == token {
                isRebuilding = false
            }
            return
        }

        guard !Task.isCancelled, activeRebuildToken == token else {
            if activeRebuildToken == token {
                isRebuilding = false
            }
            return
        }

        prefetchTask?.cancel()
        prefetchTask = nil
        lastPrefetchBucket = nil
        displayedTracksCache = displayedTracks
        filteredTracksCache = filteredTracks
        sortedTracksCache = sortedTracks
        parentSortedTracksCache = parentSortedTracks
        sortedTrackIndexMapCache = Dictionary(
            uniqueKeysWithValues: snapshot.trackIDs.enumerated().map { ($0.element, $0.offset) })
        parentSortedTrackIndexMapCache = Dictionary(
            uniqueKeysWithValues: parentSortedTracks.enumerated().map { ($0.element.id, $0.offset) }
        )
        trackByIDCache = Dictionary(uniqueKeysWithValues: sortedTracks.map { ($0.id, $0) })
        viewSnapshot = snapshot
        selectedTrackIDs.formIntersection(Set(sortedTracks.map(\.id)))
        if restoreScroll {
            restoreScrollIfNeeded()
        }
        updateLibrarySnapshot()
        syncPlayerQueueIfNeeded(with: parentSortedTracks)
        isRebuilding = false
        let rebuildDurationMs = (ProcessInfo.processInfo.systemUptime - rebuildStart) * 1000
        PlaylistPerfDiagnostics.markListRebuild(
            reason: reason,
            trackCount: snapshot.trackCount,
            durationMs: rebuildDurationMs
        )
    }

    private func currentDisplayedTracks() -> [Track] {
        switch libraryVM.currentSelection {
        case .allSongs:
            return libraryVM.allTracks.filter { $0.availability != .missing }
        case .playlist(let id):
            if let playlist = libraryVM.playlists.first(where: { $0.id == id }) {
                return playlist.tracks.filter { $0.availability != .missing }
            }
            return []
        case .artist(let key):
            return libraryVM.allTracks.filter {
                LibraryNormalization.normalizeArtist($0.artist) == key
                    && $0.availability != .missing
            }
        case .album(let key):
            return libraryVM.allTracks.filter {
                LibraryNormalization.normalizedAlbumKey(album: $0.album, artist: $0.artist)
                    == key && $0.availability != .missing
            }
        }
    }

    private func syncPlayerQueueIfNeeded(with tracks: [Track]) {
        let trackIDs = tracks.map(\.id)
        guard trackIDs != lastQueueTrackIDs else { return }
        lastQueueTrackIDs = trackIDs
        playerVM.updateQueueTracks(tracks)
    }

    private func trackRowModel(for snapshot: TrackRowSnapshot) -> TrackRowModel {
        TrackRowModel(
            id: snapshot.trackID,
            title: snapshot.title,
            artist: snapshot.artist,
            durationText: snapshot.durationText,
            artworkData: snapshot.artworkData,
            artworkCacheKey: snapshot.artworkCacheKey,
            isMissing: snapshot.isMissing
        )
    }

    private func prefetchAroundTrackID(_ trackID: UUID) {
        guard let startIndex = sortedTrackIndexMapCache[trackID] else { return }
        let bucket = startIndex / 3
        guard bucket != lastPrefetchBucket else { return }
        lastPrefetchBucket = bucket
        let rowScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let rowPixels = CGSize(
            width: Constants.Layout.artworkSmallSize * rowScale,
            height: Constants.Layout.artworkSmallSize * rowScale
        )
        let start = min(startIndex + 1, viewSnapshot.trackIDs.count)
        let end = min(viewSnapshot.trackIDs.count, startIndex + 9)
        guard start < end else { return }

        let requests: [ArtworkPrefetchRequest] = Array(viewSnapshot.trackIDs[start..<end]).compactMap {
            trackID in
            guard let snapshot = viewSnapshot.snapshot(for: trackID) else { return nil }
            return ArtworkPrefetchRequest(
                cacheKey: snapshot.artworkCacheKey,
                artworkData: snapshot.artworkData,
                targetPixelSize: rowPixels
            )
        }
        prefetchTask?.cancel()
        prefetchTask = ArtworkLoader.prefetch(Array(requests))
    }

    private func applyTargetedTrackRefresh(trackID: UUID) {
        guard let track = latestTrackFromLibrary(trackID: trackID) else { return }
        guard let sortIndex = sortedTrackIndexMapCache[trackID] else { return }

        let rowScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let rowPixels = CGSize(
            width: Constants.Layout.artworkSmallSize * rowScale,
            height: Constants.Layout.artworkSmallSize * rowScale
        )
        let checksum = ArtworkLoader.checksum(for: track.artworkData)
        let cacheKey = ArtworkLoader.cacheKey(
            trackID: track.id,
            checksum: checksum,
            targetPixelSize: rowPixels
        )

        displayedTracksCache = displayedTracksCache.map { $0.id == trackID ? track : $0 }
        filteredTracksCache = filteredTracksCache.map { $0.id == trackID ? track : $0 }
        sortedTracksCache = sortedTracksCache.map { $0.id == trackID ? track : $0 }
        parentSortedTracksCache = parentSortedTracksCache.map { $0.id == trackID ? track : $0 }

        let rowSnapshot = TrackRowSnapshot(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            durationText: formatDuration(track.duration),
            artworkChecksum: checksum,
            artworkData: track.artworkData,
            artworkCacheKey: cacheKey,
            isMissing: track.availability == .missing,
            sortIndex: sortIndex + 1
        )

        var updatedSnapshots = viewSnapshot.trackSnapshots
        updatedSnapshots[trackID] = rowSnapshot
        viewSnapshot = PlaylistViewSnapshot(
            playlistID: viewSnapshot.playlistID,
            trackIDs: viewSnapshot.trackIDs,
            trackSnapshots: updatedSnapshots,
            totalDuration: viewSnapshot.totalDuration
        )

        trackByIDCache[trackID] = track
        lastPrefetchBucket = nil
    }

    private func latestTrackFromLibrary(trackID: UUID) -> Track? {
        if let track = libraryVM.allTracks.first(where: { $0.id == trackID }) {
            return track
        }
        return trackByIDCache[trackID]
    }

    private func formatDuration(_ duration: Double) -> String {
        guard duration.isFinite, duration > 0 else { return "0:00" }
        let totalSeconds = Int(duration.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Preference Keys for Header Artwork (shared with LibraryDetailHeaderView)

struct HeaderArtworkBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

struct HeaderArtworkImagePreferenceKey: PreferenceKey {
    static var defaultValue: NSImage?
    static func reduce(value: inout NSImage?, nextValue: () -> NSImage?) {
        value = nextValue() ?? value
    }
}

private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Preview

#Preview("Playlist Detail") { @MainActor in
    let repository = StubLibraryRepository()
    let libraryVM = LibraryViewModel(repository: repository)
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)

    PlaylistDetailView()
        .environment(libraryVM)
        .environment(playerVM)
        .environmentObject(ThemeStore.shared)
        .frame(width: 500, height: 400)
        .task {
            await libraryVM.load()
        }
}
