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
    @Environment(LyricsViewModel.self) private var lyricsVM

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var dragStartLyricsWidth: CGFloat?
    @State private var dragWidthBounds: ClosedRange<CGFloat>?
    @State private var isHoveringResizeHandle = false
    @State private var windowWidth: CGFloat = 0
    @State private var lyricsFlashFilled = false
    @State private var lyricsFlashTicket = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(
                            min: Constants.Layout.sidebarMinWidth,
                            ideal: uiState.sidebarLastWidth,
                            max: Constants.Layout.sidebarMaxWidth
                        )
                        .navigationTitle("")
                } detail: {
                    ZStack(alignment: .bottom) {
                        switch uiState.contentMode {
                        case .library:
                            libraryLayout
                        case .nowPlaying:
                            nowPlayingLayout
                        }

                        MiniPlayerView()
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                    .ignoresSafeArea(.container, edges: .top)
                    .overlay {
                        ZStack {
                            if uiState.contentMode == .nowPlaying {
                                GeometryReader { detailProxy in
                                    lyricsToggleOverlay
                                        .offset(y: -detailProxy.safeAreaInsets.top)
                                        .frame(
                                            maxWidth: .infinity,
                                            maxHeight: .infinity,
                                            alignment: .topTrailing
                                        )
                                }
                            }

                        }
                    }
                    .navigationTitle("")
                }
                .navigationSplitViewStyle(.balanced)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
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
            .task {
                await libraryVM.load()
            }
            .onAppear {
                columnVisibility = uiState.sidebarVisible ? .all : .detailOnly
                updateWindowWidth(proxy.size.width)
            }
            .onChange(of: proxy.size.width) { _, newWidth in
                updateWindowWidth(newWidth)
            }
            .onChange(of: columnVisibility) { _, newValue in
                let shouldShowSidebar = newValue != .detailOnly
                if shouldShowSidebar != uiState.sidebarVisible {
                    uiState.sidebarVisible = shouldShowSidebar
                }
            }
            .onChange(of: uiState.sidebarVisible) { _, newValue in
                let desiredVisibility: NavigationSplitViewVisibility = newValue ? .all : .detailOnly
                if columnVisibility != desiredVisibility {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        columnVisibility = desiredVisibility
                    }
                }
                uiState.lyricsWidth = clampLyricsWidth(uiState.lyricsWidth)
            }
            .onChange(of: uiState.sidebarLastWidth) { _, _ in
                uiState.lyricsWidth = clampLyricsWidth(uiState.lyricsWidth)
            }
        }
    }

    // MARK: - Lyrics Resizing

    private var lyricsResizeHandle: some View {
        Color.clear
            .frame(width: 12)
            .contentShape(Rectangle())
            .overlay(
                Rectangle()
                    .fill(Color.primary.opacity(isHoveringResizeHandle ? 0.1 : 0))
                    .frame(width: 1)
                    .allowsHitTesting(false)
            )
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
        let minWidth = min(Constants.Layout.lyricsPanelMinWidth, maxWidth)
        return minWidth...maxWidth
    }

    private var lyricsToggleButton: some View {
        GlassIconButton(
            systemImage: lyricsFlashFilled ? "quote.bubble.fill" : "quote.bubble",
            size: GlassStyleTokens.headerControlHeight,
            iconSize: GlassToolbarButton.iconSize(for: .standard),
            isPrimary: false,
            help: uiState.lyricsVisible ? "Hide Lyrics" : "Show Lyrics",
            surfaceVariant: .defaultToolbar
        ) {
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
        .contentTransition(
            .symbolEffect(.replace.magic(fallback: .offUp.byLayer), options: .nonRepeating)
        )
        .animation(.snappy(duration: 0.22), value: lyricsFlashFilled)
    }

    private var lyricsToggleOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                lyricsToggleButton
            }
            .cornerAvoidingHorizontalPadding(GlassStyleTokens.headerHorizontalPadding)
            .frame(height: GlassStyleTokens.headerBarHeight)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Layout Variants

    private var libraryLayout: some View {
        HStack(spacing: 0) {
            PlaylistDetailView {
                lyricsToggleButton
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(1)

            if uiState.lyricsVisible && !uiState.lyricsPanelSuppressedByModal {
                lyricsPanelView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var nowPlayingLayout: some View {
        ZStack(alignment: .topTrailing) {
            NowPlayingHostView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if uiState.lyricsVisible && !uiState.lyricsPanelSuppressedByModal {
                lyricsPanelView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var lyricsPanelView: some View {
        LyricsPanelView()
            .frame(width: uiState.lyricsWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .leading) {
                lyricsResizeHandle
            }
    }

    private func updateWindowWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        windowWidth = width
        uiState.lyricsWidth = clampLyricsWidth(uiState.lyricsWidth)
    }

    private func dynamicLyricsMaxWidth() -> CGFloat {
        let defaultMax = Constants.Layout.lyricsPanelMaxWidth
        guard windowWidth > 0 else { return defaultMax }

        let compactThreshold: CGFloat = 1300
        let minMainWidth: CGFloat = 560
        let minLyricsWidthWhenTight: CGFloat = 180
        let interPanelSpacing: CGFloat = 8

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

// MARK: - Preview

#Preview("Main Layout") { @MainActor in
    let repository = StubLibraryRepository()
    let libraryVM = LibraryViewModel(repository: repository)

    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)
    let ledMeter = LEDMeterService()
    let skinManager = SkinManager()

    let lyricsVM = LyricsViewModel()

    let uiState = UIStateViewModel()

    MainLayoutView()
        .environment(uiState)
        .environment(libraryVM)
        .environment(playerVM)
        .environment(lyricsVM)
        .environment(ledMeter)
        .environment(skinManager)
        .environmentObject(ThemeStore.shared)
        .frame(width: 1200, height: 800)
}
