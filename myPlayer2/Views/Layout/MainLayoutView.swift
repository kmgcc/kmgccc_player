//
//  MainLayoutView.swift
//  myPlayer2
//
//  kmgccc_player - Main Layout View
//  Uses NavigationSplitView for system Liquid Glass sidebar.
//
//  Design Decisions:
//  - NO global import button in toolbar
//  - Import is done within PlaylistDetailView (per-playlist)
//  - Sidebar supports collapse/restore toggle
//

import AppKit
import SwiftUI

/// Main layout using NavigationSplitView for native macOS 26 Liquid Glass.
/// - Sidebar: System-rendered glass (no custom blur/material)
/// - Main area: Content + Lyrics + MiniPlayer overlay
/// - MiniPlayer: Only covers right area, not sidebar
@MainActor
struct MainLayoutView: View {

    @Environment(UIStateViewModel.self) private var uiState
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @ObservedObject private var fullscreenWindowManager = FullscreenWindowManager.shared

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var dragStartLyricsWidth: CGFloat?
    @State private var dragWidthBounds: ClosedRange<CGFloat>?
    @State private var isHoveringResizeHandle = false
    @State private var windowWidth: CGFloat = 0
    @State private var playlistPageController = PlaylistPageController()
    @State private var lyricsFlashFilled = false
    @State private var lyricsFlashTicket = 0
    @State private var sortSymbolEffectTrigger = 0
    @State private var lastTracedDetailSize: CGSize = .zero
    @State private var lastTracedDetailSafeAreaTop: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                splitViewContent
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)

            .background(
                WindowToolbarAccessor { window in
                    window.styleMask.insert(.fullSizeContentView)
                    window.titlebarAppearsTransparent = true
                    if #available(macOS 11.0, *) {
                        window.titlebarSeparatorStyle = .none
                    }
                    // Keep window dragging on titlebar only; avoid conflicts with custom resize dividers.
                    window.isMovableByWindowBackground = false
                    window.titleVisibility = .hidden
                }
            )
            .task(id: libraryVM.state) {
                // Only load when state is .loading (initial or refresh).
                // This prevents re-execution when view re-appears due to sheet dismiss.
                guard libraryVM.state == .loading else {
                    return
                }
                await libraryVM.load()
            }
            .onAppear {
                syncColumnVisibility(animated: false)
                updateWindowWidth(proxy.size.width)
                if EmbeddedFullscreenTrace.enabled {
                    Log.info(
                        "[EFS t=\(EmbeddedFullscreenTrace.stamp())] MainLayoutView.appear windowSize=\(proxy.size) sidebarVisible=\(uiState.sidebarVisible) sidebarLastWidth=\(uiState.sidebarLastWidth) columnVisibility=\(columnVisibility)",
                        category: .fullscreen
                    )
                }
            }
            .onChange(of: proxy.size.width) { _, newWidth in
                updateWindowWidth(newWidth)
                if EmbeddedFullscreenTrace.enabled {
                    Log.info(
                        "[EFS t=\(EmbeddedFullscreenTrace.stamp())] MainLayoutView.windowWidthChanged width=\(String(format: "%.1f", newWidth)) columnVisibility=\(columnVisibility)",
                        category: .fullscreen
                    )
                }
            }
            .onChange(of: columnVisibility) { _, newValue in
                let shouldShowSidebar = newValue != .detailOnly
                if shouldShowSidebar != uiState.sidebarVisible {
                    uiState.sidebarVisible = shouldShowSidebar
                }
                if EmbeddedFullscreenTrace.enabled {
                    Log.info(
                        "[EFS t=\(EmbeddedFullscreenTrace.stamp())] MainLayoutView.columnVisibilityChanged value=\(newValue) sidebarVisible=\(uiState.sidebarVisible)",
                        category: .fullscreen
                    )
                }
            }
            .onChange(of: uiState.sidebarVisible) { _, _ in
                syncColumnVisibility(animated: true)
                uiState.lyricsWidth = clampLyricsWidth(uiState.lyricsWidth)
                if EmbeddedFullscreenTrace.enabled {
                    Log.info(
                        "[EFS t=\(EmbeddedFullscreenTrace.stamp())] MainLayoutView.sidebarVisibleChanged sidebarVisible=\(uiState.sidebarVisible) sidebarLastWidth=\(uiState.sidebarLastWidth)",
                        category: .fullscreen
                    )
                }
            }
            .onChange(of: uiState.sidebarLastWidth) { _, _ in
                uiState.lyricsWidth = clampLyricsWidth(uiState.lyricsWidth)
                if EmbeddedFullscreenTrace.enabled {
                    Log.info(
                        "[EFS t=\(EmbeddedFullscreenTrace.stamp())] MainLayoutView.sidebarLastWidthChanged sidebarLastWidth=\(String(format: "%.1f", uiState.sidebarLastWidth))",
                        category: .fullscreen
                    )
                }
            }
            .onChange(of: fullscreenWindowManager.isWindowedFullscreenActive) { _, _ in
                uiState.lyricsWidth = clampLyricsWidth(uiState.lyricsWidth)
                if EmbeddedFullscreenTrace.enabled {
                    Log.info(
                        "[EFS t=\(EmbeddedFullscreenTrace.stamp())] MainLayoutView.windowedFullscreenActiveChanged active=\(fullscreenWindowManager.isWindowedFullscreenActive) sidebar(min/ideal/max)=\(String(format: "%.1f", sidebarColumnMinWidth))/\(String(format: "%.1f", sidebarColumnIdealWidth))/\(String(format: "%.1f", sidebarColumnMaxWidth))",
                        category: .fullscreen
                    )
                }
            }
            .onChange(of: libraryVM.searchResetTrigger) { _, _ in
                playlistPageController.searchText = ""
            }
        }
    }

    @ViewBuilder
    private var splitViewContent: some View {
        let baseSplitView = NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: sidebarColumnMinWidth,
                    ideal: sidebarColumnIdealWidth,
                    max: sidebarColumnMaxWidth
                )
                .opacity(shouldForceSidebarHiddenInWindowedFullscreen ? 0 : 1)
                .allowsHitTesting(!shouldForceSidebarHiddenInWindowedFullscreen)
                .navigationTitle("")
        } detail: {
            ZStack(alignment: .bottom) {
                detailBaseContent
                    .allowsHitTesting(!fullscreenWindowManager.isWindowedFullscreenActive)

                if !fullscreenWindowManager.isWindowedFullscreenActive {
                    GeometryReader { detailProxy in
                        MiniPlayerView()
                            .frame(
                                width: miniPlayerAvailableWidth(in: detailProxy.size.width),
                                alignment: .leading
                            )
                            .padding(.leading, GlassStyleTokens.miniPlayerHorizontalPadding)
                            .padding(.bottom, 12)
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .bottomLeading
                            )
                    }
                }

                if fullscreenWindowManager.isWindowedFullscreenActive {
                    embeddedFullscreenPlayerRoute
                }
            }
            .background(
                GeometryReader { detailProxy in
                    Color.clear
                        .onAppear {
                            traceDetailGeometry(detailProxy)
                        }
                        .onChange(of: detailProxy.size) { _, _ in
                            traceDetailGeometry(detailProxy)
                        }
                }
            )
            .modifier(TopSafeAreaMode(enabled: shouldIgnoreTopContainerSafeArea))
            .navigationTitle("")
            .id("main-detail-content")
        }
        .id("main-split-view")
        .navigationSplitViewStyle(.balanced)
        .modifier(SplitViewSafeAreaMode(ignoreTop: shouldIgnoreTopContainerSafeArea))

        let removeSidebarToggle = shouldForceSidebarHiddenInWindowedFullscreen || uiState.sidebarVisible

        if shouldForceSidebarHiddenInWindowedFullscreen {
            baseSplitView
                .toolbar(removing: .sidebarToggle)
                .toolbar(.hidden, for: .windowToolbar)
        } else if uiState.contentMode == .library {
            baseSplitView
                .toolbar(removing: removeSidebarToggle ? .sidebarToggle : nil)
        } else {
            baseSplitView
                .toolbar(removing: removeSidebarToggle ? .sidebarToggle : nil)
        }
    }

    @ViewBuilder
    private var detailBaseContent: some View {
        switch uiState.contentMode {
        case .library:
            libraryLayout
        case .nowPlaying:
            nowPlayingLayout
        }
    }

    private var embeddedFullscreenPlayerRoute: some View {
        FullscreenPlayerView(hostContext: .embeddedWindow) {
            fullscreenWindowManager.closeFullscreenPlayerInWindow()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .zIndex(1)
    }

    private var shouldForceSidebarHiddenInWindowedFullscreen: Bool {
        fullscreenWindowManager.isWindowedFullscreenActive
    }

    private var librarySearchBinding: Binding<String> {
        Binding(
            get: { playlistPageController.searchText },
            set: { playlistPageController.searchText = $0 }
        )
    }

    @ToolbarContentBuilder
    private var libraryToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            sortToolbarMenu
        }

        ToolbarItem(placement: .navigation) {
            libraryActionGroup
        }

        ToolbarSpacer(.flexible, placement: .automatic)

        ToolbarItem(placement: .secondaryAction) {
            lyricsToolbarButton
        }
    }

    private var sortToolbarMenu: some View {
        Menu {
            Section("sort.by") {
                ForEach(TrackSortKey.allCases) { key in
                    Button {
                        libraryVM.trackSortKey = key
                        sortSymbolEffectTrigger += 1
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
                        sortSymbolEffectTrigger += 1
                    } label: {
                        if libraryVM.trackSortOrder == order {
                            Label(order.title, systemImage: "checkmark")
                        } else {
                            Text(order.title)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .symbolRenderingMode(.hierarchical)
        }
        .help("sort.help")
        .symbolEffect(.bounce, value: sortSymbolEffectTrigger)
    }

    private var libraryActionGroup: some View {
        ControlGroup {
            Button {
                toggleMultiselectMode()
            } label: {
                Image(systemName: playlistPageController.isMultiselectMode ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .help("context.multiselect")

            Button {
                playFromToolbar()
            } label: {
                Image(systemName: "play.fill")
            }
            .help("context.play_all")
            .disabled(toolbarQueueTracks.isEmpty)

            Button {
                Task {
                    await libraryVM.importToCurrentPlaylist()
                }
            } label: {
                Image(systemName: "plus")
            }
            .help("context.import")
        }
        .controlGroupStyle(.navigation)
    }

    private var toolbarQueueTracks: [Track] {
        playlistPageController.page?.queueTracks ?? []
    }

    private var toolbarSelectionIdentity: String {
        if let identity = playlistPageController.page?.selectionIdentity {
            return identity
        }
        switch libraryVM.currentSelection {
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

    private func toggleMultiselectMode() {
        guard let page = playlistPageController.page, !page.rows.isEmpty else { return }
        playlistPageController.isMultiselectMode.toggle()
        if !playlistPageController.isMultiselectMode {
            playlistPageController.selectedTrackIDs.removeAll()
        }
    }

    private func playFromToolbar() {
        if playlistPageController.isMultiselectMode,
           !playlistPageController.selectedTrackIDs.isEmpty
        {
            let selectedTracks = selectedTracksForToolbar()
            guard !selectedTracks.isEmpty else { return }
            playbackCoordinator.playTracks(
                selectedTracks,
                libraryQueueSource: .librarySelection(toolbarSelectionIdentity)
            )
            return
        }

        guard !toolbarQueueTracks.isEmpty else { return }
        playbackCoordinator.playTracks(
            toolbarQueueTracks,
            libraryQueueSource: .librarySelection(toolbarSelectionIdentity)
        )
    }

    private func selectedTracksForToolbar() -> [Track] {
        guard let rows = playlistPageController.page?.rows else { return [] }
        return rows.compactMap { row in
            guard playlistPageController.selectedTrackIDs.contains(row.id) else { return nil }
            return playlistPageController.latestTrackFromLibrary(trackID: row.id)
        }
    }

    private func traceDetailGeometry(_ detailProxy: GeometryProxy) {
        guard EmbeddedFullscreenTrace.enabled else { return }
        let size = detailProxy.size
        let safeTop = detailProxy.safeAreaInsets.top
        let sizeChanged =
            abs(size.width - lastTracedDetailSize.width) > 0.5
            || abs(size.height - lastTracedDetailSize.height) > 0.5
        let safeChanged = abs(safeTop - lastTracedDetailSafeAreaTop) > 0.5
        guard sizeChanged || safeChanged else { return }
        lastTracedDetailSize = size
        lastTracedDetailSafeAreaTop = safeTop
        Log.info(
            "[EFS t=\(EmbeddedFullscreenTrace.stamp())] MainLayoutView.detailGeometry size=\(size) safeTop=\(String(format: "%.1f", safeTop)) windowedFullscreen=\(fullscreenWindowManager.isWindowedFullscreenActive)",
            category: .fullscreen
        )
    }

    private var desiredColumnVisibility: NavigationSplitViewVisibility {
        uiState.sidebarVisible ? .all : .detailOnly
    }

    private func syncColumnVisibility(animated: Bool) {
        guard columnVisibility != desiredColumnVisibility else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                columnVisibility = desiredColumnVisibility
            }
            return
        }

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            columnVisibility = desiredColumnVisibility
        }
    }

    private var sidebarColumnMinWidth: CGFloat {
        shouldForceSidebarHiddenInWindowedFullscreen ? 0 : Constants.Layout.sidebarMinWidth
    }

    private var sidebarColumnIdealWidth: CGFloat {
        shouldForceSidebarHiddenInWindowedFullscreen ? 0 : uiState.sidebarLastWidth
    }

    private var sidebarColumnMaxWidth: CGFloat {
        shouldForceSidebarHiddenInWindowedFullscreen ? 0 : Constants.Layout.sidebarMaxWidth
    }

    // MARK: - Lyrics Resizing

    private var lyricsResizeHandle: some View {
        Color.clear
            .frame(width: 12)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(isHoveringResizeHandle ? 0.1 : 0))
                    .frame(width: 1)
                    .offset(x: -0.5)
                    .allowsHitTesting(false)
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .local)
                    .onChanged { value in
                        if dragStartLyricsWidth == nil {
                            dragStartLyricsWidth = uiState.lyricsWidth
                            dragWidthBounds = currentLyricsWidthBounds()
                        }
                        let baseWidth = dragStartLyricsWidth ?? uiState.lyricsWidth
                        let proposed = baseWidth - value.translation.width
                        uiState.lyricsWidth = clampDuringDrag(proposed)
                    }
                    .onEnded { _ in
                        dragStartLyricsWidth = nil
                        dragWidthBounds = nil
                        uiState.lyricsWidth = clampLyricsWidth(uiState.lyricsWidth)
                    },
                including: .gesture
            )
            .onHover { hovering in
                if hovering, !isHoveringResizeHandle {
                    isHoveringResizeHandle = true
                    NSCursor.resizeLeftRight.push()
                } else if !hovering, isHoveringResizeHandle {
                    isHoveringResizeHandle = false
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHoveringResizeHandle {
                    isHoveringResizeHandle = false
                    NSCursor.pop()
                }
            }
    }

    private func clampLyricsWidth(_ width: CGFloat) -> CGFloat {
        let bounds = currentLyricsWidthBounds()
        return min(max(width, bounds.lowerBound), bounds.upperBound)
    }

    private func clampDuringDrag(_ width: CGFloat) -> CGFloat {
        let bounds = dragWidthBounds ?? currentLyricsWidthBounds()
        return min(max(width, bounds.lowerBound), bounds.upperBound)
    }

    private func currentLyricsWidthBounds() -> ClosedRange<CGFloat> {
        let maxWidth = dynamicLyricsMaxWidth()
        let minWidth = Constants.Layout.lyricsPanelMinWidth
        let resolvedMax = max(minWidth, maxWidth)
        return minWidth...resolvedMax
    }

    private var lyricsToolbarButton: some View {
        Button {
            toggleLyrics()
        } label: {
            Image(systemName: lyricsFlashFilled ? "quote.bubble.fill" : "quote.bubble")
                .symbolRenderingMode(.hierarchical)
        }
        .help(uiState.lyricsVisible ? "Hide Lyrics" : "Show Lyrics")
        .contentTransition(
            .symbolEffect(.replace.magic(fallback: .offUp.byLayer), options: .nonRepeating)
        )
        .animation(.snappy(duration: 0.22), value: lyricsFlashFilled)
    }

    private func toggleLyrics() {
        lyricsFlashTicket += 1
        let ticket = lyricsFlashTicket
        lyricsFlashFilled = true
        uiState.toggleLyrics()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            if lyricsFlashTicket == ticket {
                lyricsFlashFilled = false
            }
        }
    }

    // MARK: - Layout Variants

    private var libraryLayout: some View {
        GeometryReader { proxy in
            let mainContentWidth = resolvedMainContentWidth(in: proxy.size.width)
            let lyricsWidth = resolvedLyricsPanelWidth(in: proxy.size.width)

            HStack(spacing: 0) {
                PlaylistDetailView(pageController: playlistPageController)
                    .frame(width: mainContentWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .layoutPriority(1)
                    .toolbar { libraryToolbarContent }
                    .searchable(
                        text: librarySearchBinding,
                        placement: .toolbar,
                        prompt: Text("搜索")
                    )

                if shouldShowMainLyricsPanel {
                    lyricsPanelView(width: lyricsWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .id("library-layout")
    }

    private var nowPlayingLayout: some View {
        GeometryReader { proxy in
            let mainContentWidth = resolvedMainContentWidth(in: proxy.size.width)
            let lyricsWidth = resolvedLyricsPanelWidth(in: proxy.size.width)

            ZStack(alignment: .topLeading) {
                NowPlayingHostView(mainContentWidth: mainContentWidth)
                    .frame(width: mainContentWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)

                if shouldShowMainLyricsPanel {
                    lyricsPanelView(width: lyricsWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func lyricsPanelView(width: CGFloat) -> some View {
        MainLyricsPanelShell(width: width)
            .equatable()
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .leading) {
                lyricsResizeHandle
            }
    }

    private var shouldShowMainLyricsPanel: Bool {
        uiState.lyricsVisible
            && !uiState.lyricsPanelSuppressedByModal
            && !fullscreenWindowManager.usesFullscreenPlayerUI
    }

    private func resolvedLyricsPanelWidth(in detailWidth: CGFloat) -> CGFloat {
        guard shouldShowMainLyricsPanel else { return 0 }
        let maxWidthPreservingDetail = max(
            Constants.Layout.lyricsPanelMinWidth,
            detailWidth - Constants.Layout.detailContentMinWidth
        )
        let clampedStateWidth = min(
            uiState.lyricsWidth,
            Constants.Layout.lyricsPanelMaxWidth,
            maxWidthPreservingDetail
        )
        return max(Constants.Layout.lyricsPanelMinWidth, clampedStateWidth)
    }

    private func resolvedMainContentWidth(in detailWidth: CGFloat) -> CGFloat {
        max(0, detailWidth - resolvedLyricsPanelWidth(in: detailWidth))
    }

    private func miniPlayerAvailableWidth(in detailWidth: CGFloat) -> CGFloat {
        max(
            0,
            resolvedMainContentWidth(in: detailWidth)
                - GlassStyleTokens.miniPlayerHorizontalPadding * 2
        )
    }

    private func updateWindowWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        windowWidth = width
        uiState.lyricsWidth = clampLyricsWidth(uiState.lyricsWidth)
    }

    private var shouldIgnoreTopContainerSafeArea: Bool {
        uiState.contentMode == .nowPlaying || fullscreenWindowManager.isWindowedFullscreenActive
    }

    private func dynamicLyricsMaxWidth() -> CGFloat {
        let defaultMax = Constants.Layout.lyricsPanelMaxWidth
        guard windowWidth > 0 else { return defaultMax }

        let compactThreshold: CGFloat = 1300
        let minMainWidth = Constants.Layout.detailContentMinWidth
        let minLyricsWidthWhenTight: CGFloat = Constants.Layout.lyricsPanelMinWidth
        let interPanelSpacing: CGFloat = 0

        guard windowWidth < compactThreshold else { return defaultMax }

        let sidebarFootprint =
            uiState.sidebarVisible
            ? max(uiState.sidebarLastWidth, Constants.Layout.sidebarMinWidth)
            : 0
        let detailWidth = max(0, windowWidth - sidebarFootprint)
        let maxByMainReserve = detailWidth - minMainWidth - interPanelSpacing
        let compactMax = max(minLyricsWidthWhenTight, maxByMainReserve)
        return min(defaultMax, compactMax)
    }

}

private struct TopSafeAreaMode: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.ignoresSafeArea(.container, edges: .top)
        } else {
            content
        }
    }
}

private struct SplitViewSafeAreaMode: ViewModifier {
    let ignoreTop: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if ignoreTop {
            content.ignoresSafeArea(.container, edges: [.top, .bottom])
        } else {
            content.ignoresSafeArea(.container, edges: .bottom)
        }
    }
}

private struct MainLyricsPanelShell: View, Equatable {
    let width: CGFloat

    static func == (lhs: MainLyricsPanelShell, rhs: MainLyricsPanelShell) -> Bool {
        abs(lhs.width - rhs.width) < 0.5
    }

    var body: some View {
        LyricsPanelView()
            .frame(width: width)
    }
}

// MARK: - Preview

#Preview("Main Layout") { @MainActor in
    let repository = StubLibraryRepository()
    let libraryVM = LibraryViewModel(repository: repository)

    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)
    let appleMusicAdapter = AppleMusicPlaybackAdapter(libraryVM: libraryVM)
    let playbackCoordinator = PlaybackCoordinator(
        playerVM: playerVM,
        appleMusicAdapter: appleMusicAdapter
    )
    let ledMeter = LEDMeterService()
    let skinManager = SkinManager()

    let lyricsVM = LyricsViewModel()

    let uiState = UIStateViewModel()

    MainLayoutView()
        .environment(uiState)
        .environment(libraryVM)
        .environment(playerVM)
        .environment(playbackCoordinator)
        .environment(lyricsVM)
        .environment(ledMeter)
        .environment(skinManager)
        .environmentObject(ThemeStore.shared)
        .frame(width: 1200, height: 800)
}
