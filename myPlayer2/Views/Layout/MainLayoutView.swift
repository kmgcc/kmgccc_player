//
//  MainLayoutView.swift
//  myPlayer2
//
//  TrueMusic - Main Layout View
//  Uses NavigationSplitView for system Liquid Glass sidebar.
//
//  Design Decisions:
//  - NO global import button in toolbar
//  - Import is done within PlaylistDetailView (per-playlist)
//  - Sidebar always visible (no toggle)
//

import SwiftUI

/// Main layout using NavigationSplitView for native macOS 26 Liquid Glass.
/// - Sidebar: System-rendered glass (no custom blur/material)
/// - Main area: Content + Lyrics + MiniPlayer overlay
/// - MiniPlayer: Only covers right area, not sidebar
struct MainLayoutView: View {

    @Environment(UIStateViewModel.self) private var uiState
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(LyricsViewModel.self) private var lyricsVM

    /// Fixed column visibility - sidebar always visible
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var dragStartLyricsWidth: CGFloat?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // MARK: - Sidebar Column (System Glass - NO custom blur!)
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            // MARK: - Detail Column (Main + Lyrics + MiniPlayer overlay)
            ZStack(alignment: .bottom) {
                // Content + Lyrics horizontal stack
                HStack(spacing: 0) {
                    // Main content (library or now playing)
                    mainContentArea
                        .frame(maxWidth: .infinity)
                        .layoutPriority(1)

                    // Lyrics panel (toggleable)
                    if uiState.lyricsVisible {
                        lyricsResizeHandle

                        LyricsPanelView()
                            .frame(width: uiState.lyricsWidth)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // MiniPlayer (only in detail area, not covering sidebar)
                MiniPlayerView()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            // Allow lyrics glass + floating controls to reach the window top.
            .ignoresSafeArea(.container, edges: .top)
            .overlay(alignment: .topTrailing) {
                lyricsToggleButton
            }
        }
        // Force sidebar always visible - disable hiding
        .navigationSplitViewStyle(.balanced)
        // Sidebar is always visible; remove the system sidebar toggle button.
        .toolbar(removing: .sidebarToggle)
        // Some builds still show the default AppKit toolbar toggle; remove it at the window level.
        .background(
            WindowToolbarAccessor { window in
                // Make the titlebar transparent so content can reach the top.
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = true

                // Fully remove the AppKit toolbar to prevent the default sidebar toggle.
                if let toolbar = window.toolbar {
                    toolbar.isVisible = false
                    for (idx, item) in toolbar.items.enumerated().reversed() {
                        if item.itemIdentifier == .toggleSidebar {
                            toolbar.removeItem(at: idx)
                        }
                    }
                }
                window.toolbar = nil
                window.standardWindowButton(.toolbarButton)?.isHidden = true
            }
        )
        .task {
            await libraryVM.load()
        }
        // Lock column visibility to always show sidebar
        .onChange(of: columnVisibility) { _, newValue in
            if newValue != .all {
                columnVisibility = .all
            }
        }
    }

    // MARK: - Lyrics Resizing

    private var lyricsResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .overlay(
                Divider()
                    .opacity(0.35)
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartLyricsWidth == nil {
                            dragStartLyricsWidth = uiState.lyricsWidth
                        }
                        let baseWidth = dragStartLyricsWidth ?? uiState.lyricsWidth
                        let proposed = baseWidth - value.translation.width
                        uiState.lyricsWidth = clampLyricsWidth(proposed)
                    }
                    .onEnded { _ in
                        dragStartLyricsWidth = nil
                    }
            )
    }

    private func clampLyricsWidth(_ width: CGFloat) -> CGFloat {
        min(
            max(width, Constants.Layout.lyricsPanelMinWidth),
            Constants.Layout.lyricsPanelMaxWidth
        )
    }

    private var lyricsToggleButton: some View {
        Button {
            uiState.toggleLyrics()
        } label: {
            Image(systemName: "text.quote")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .liquidGlass(in: Circle())
        .help(uiState.lyricsVisible ? "Hide Lyrics" : "Show Lyrics")
        .padding(.top, 4)
        .padding(.trailing, 10)
    }

    // MARK: - Main Content Area

    @ViewBuilder
    private var mainContentArea: some View {
        switch uiState.contentMode {
        case .library:
            PlaylistDetailView()
                .safeAreaPadding(.top)
        case .nowPlaying:
            NowPlayingView()
                .safeAreaPadding(.top)
        }
    }
}

// MARK: - Preview

#Preview("Main Layout") {
    let repository = StubLibraryRepository()
    let libraryVM = LibraryViewModel(repository: repository)

    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)

    let bridgeService = StubLyricsBridgeService()
    let lyricsVM = LyricsViewModel(bridgeService: bridgeService)

    let uiState = UIStateViewModel()

    MainLayoutView()
        .environment(uiState)
        .environment(libraryVM)
        .environment(playerVM)
        .environment(lyricsVM)
        .frame(width: 1200, height: 800)
}
