//
//  HomeView.swift
//  myPlayer2
//
//  Home page root container.
//
//  Mounted by `HomeFullWindowRoot` inside the AppKit window's full-window
//  Home host (a sibling layer between the art background and the split
//  view). Reads `HomeWindowLayoutState.shared` to decide which sections
//  align inside the center column (Hero / Playlists / Insights / footer)
//  and which extend to full window width (album / artist carousels).
//

import SwiftUI

struct HomeView: View {
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    @Environment(HomeViewModel.self) private var homeVM
    @State private var hasAppeared = false
    @State private var layout = HomeWindowLayoutState.shared
    @State private var homeScrollY: CGFloat = 0

    var body: some View {
        Group {
            if libraryVM.state == .loading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if libraryVM.allTracks.isEmpty {
                emptyLibraryView
            } else {
                scrollContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            homeVM.refresh(from: libraryVM)
            try? await Task.sleep(for: .milliseconds(50))
            hasAppeared = true
        }
        .onChange(of: libraryVM.refreshTrigger) { _, _ in
            homeVM.refreshChangedSections(from: libraryVM)
        }
        .onChange(of: libraryVM.trackUpdateEvent) { _, event in
            guard let event else { return }
            homeVM.applyTrackUpdates(from: libraryVM, trackIDs: [event.trackID])
        }
        .onChange(of: libraryVM.artistSortKey) { _, _ in
            homeVM.refreshArtistAlbumSort(from: libraryVM)
        }
        .onChange(of: libraryVM.albumSortKey) { _, _ in
            homeVM.refreshArtistAlbumSort(from: libraryVM)
        }
        .onChange(of: libraryVM.trackSortOrder) { _, _ in
            homeVM.refreshArtistAlbumSort(from: libraryVM)
        }
        .onChange(of: libraryVM.state) { old, new in
            if new == .loaded {
                homeVM.refresh(from: libraryVM)
                if old == .loading {
                    hasAppeared = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(80))
                        hasAppeared = true
                    }
                }
            }
        }
    }

    private var scrollContent: some View {
        let g = layout.geometry
        // While the center-pane geometry probe hasn't published a valid
        // rect yet (very brief at mount time), render nothing rather than
        // briefly aligning content against the window's left edge. The
        // center pane mounts on the same frame, so this empty state is
        // only visible for ~1 layout pass before real geometry arrives.
        guard g.hasValidLayout else {
            return AnyView(
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }

        let centerW = g.centerWidth
        // Layout mode follows the center column width so card sizes match
        // the visible center area, not the full window width.
        let mode = HomeLayoutMode.mode(for: max(320, centerW))
        let hPad = mode.horizontalPadding
        let leftInset = g.leftInset
        let rightInset = g.rightInset
        let centerLeftPad = leftInset + hPad
        let centerRightPad = rightInset + hPad
        let contentWidth = max(200, centerW - hPad * 2)

        return AnyView(
            ZStack(alignment: .topLeading) {
                HomeAmbientShapesBackground(
                    geometry: g,
                    mode: mode,
                    scrollOffsetY: homeScrollY,
                    sourceColor: themeStore.semanticPalette.ambientSurface
                )
                .transaction { transaction in
                    transaction.animation = nil
                }

                homeScrollView(
                    mode: mode,
                    contentWidth: contentWidth,
                    centerLeftPad: centerLeftPad,
                    centerRightPad: centerRightPad
                )
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 12)
                .animation(.easeOut(duration: 0.4), value: hasAppeared)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
    }

    private func homeScrollView(
        mode: HomeLayoutMode,
        contentWidth: CGFloat,
        centerLeftPad: CGFloat,
        centerRightPad: CGFloat
    ) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: mode.sectionSpacing) {
                if let heroTrack = homeVM.heroTrack {
                    HomeHeroView(
                        track: heroTrack,
                        containerWidth: contentWidth,
                        mode: mode,
                        onSwitchTrack: {
                            homeVM.switchHeroTrack(from: libraryVM)
                        }
                    )
                        .padding(.leading, centerLeftPad)
                        .padding(.trailing, centerRightPad)
                }

                if !homeVM.playlists.isEmpty {
                    HomePlaylistsSection(playlists: homeVM.playlists, mode: mode)
                        .padding(.leading, centerLeftPad)
                        .padding(.trailing, centerRightPad)
                }

                if !homeVM.artists.isEmpty {
                    HomeArtistsSection(
                        artists: homeVM.artists,
                        mode: mode,
                        centerLeftPad: centerLeftPad,
                        centerRightPad: centerRightPad
                    )
                }

                if !homeVM.albums.isEmpty {
                    HomeAlbumsSection(
                        albums: homeVM.albums,
                        mode: mode,
                        centerLeftPad: centerLeftPad,
                        centerRightPad: centerRightPad
                    )
                }

                HomeInsightsSection(
                    homeVM: homeVM,
                    mode: mode,
                    containerWidth: contentWidth,
                    centerLeftPad: centerLeftPad,
                    centerRightPad: centerRightPad
                )

                footer
                    .padding(.leading, centerLeftPad)
                    .padding(.trailing, centerRightPad)

                // Bottom safe space so the Mini Player doesn't cover footer text.
                Color.clear.frame(height: 120)
            }
            // Top safe-area inset so the Hero card clears the unified
            // titlebar/toolbar at the initial scroll position. The
            // window uses `.fullSizeContentView`, so the toolbar
            // occupies the top ~52pt of the content area; 56pt gives
            // the Hero a comfortable cushion below it.
            .padding(.top, 56)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            let rawOffset = max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            return (rawOffset * 2).rounded() / 2
        } action: { _, newValue in
            guard abs(homeScrollY - newValue) >= 0.5 else { return }
            homeScrollY = newValue
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var emptyLibraryView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.house")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("你的音乐库是空的")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("导入一些音乐来开始吧")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text("\u{201C}Where words fail, music speaks.\u{201D}")
                .font(.system(size: 20, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text("\u{8A00}\u{6240}\u{4E0D}\u{53CA}\u{5904}\u{FF0C}\u{7B19}\u{7BAB}\u{76F8}\u{7EE7}\u{3002}")
                .font(.system(.callout, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("— Hans Christian Andersen")
                .font(.system(.caption2, weight: .ultraLight))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.quaternary)
                .padding(.top, 4)
        }
        .padding(.top, 36)
        .padding(.bottom, 24)
    }
}

// MARK: - Layout Mode

enum HomeLayoutMode {
    case wide      // >= 980
    case medium    // 720..<980
    case compact   // 560..<720
    case narrow    // < 560

    static func mode(for width: CGFloat) -> HomeLayoutMode {
        if width >= 980 { return .wide }
        if width >= 720 { return .medium }
        if width >= 560 { return .compact }
        return .narrow
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .wide:    return 40
        case .medium:  return 32
        case .compact: return 24
        case .narrow:  return 18
        }
    }

    var sectionSpacing: CGFloat {
        switch self {
        case .wide: return 36
        case .medium: return 32
        case .compact: return 26
        case .narrow: return 22
        }
    }

    var sectionTitleFontSize: CGFloat {
        switch self {
        case .wide: return 22
        case .medium: return 20
        case .compact: return 18
        case .narrow: return 17
        }
    }
}
