//
//  HomeView.swift
//  myPlayer2
//
//  Home page root container.
//  Composes Hero, Albums, Artists, Playlists, and Insights sections.
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
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 12)
                    .animation(.easeOut(duration: 0.4), value: hasAppeared)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            homeVM.refresh(from: libraryVM)
            try? await Task.sleep(for: .milliseconds(50))
            hasAppeared = true
        }
        .onChange(of: libraryVM.refreshTrigger) { _, _ in
            homeVM.refresh(from: libraryVM)
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
        GeometryReader { geo in
            let mode = HomeLayoutMode.mode(for: geo.size.width)
            let hPad = mode.horizontalPadding
            let contentWidth = max(200, geo.size.width - hPad * 2)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: mode.sectionSpacing) {
                    if let heroTrack = homeVM.heroTrack {
                        HomeHeroView(track: heroTrack, containerWidth: contentWidth, mode: mode)
                    }

                    if !homeVM.albums.isEmpty {
                        HomeAlbumsSection(
                            albums: homeVM.albums,
                            mode: mode
                        )
                    }

                    if !homeVM.artists.isEmpty {
                        HomeArtistsSection(
                            artists: homeVM.artists,
                            mode: mode
                        )
                    }

                    if !homeVM.playlists.isEmpty {
                        HomePlaylistsSection(playlists: homeVM.playlists, mode: mode)
                    }

                    HomeInsightsSection(
                        homeVM: homeVM,
                        mode: mode,
                        containerWidth: contentWidth
                    )

                    footer

                    // Bottom safe space so the Mini Player doesn't cover footer text.
                    Color.clear.frame(height: 120)
                }
                .padding(.horizontal, hPad)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
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
                .font(.system(size: 20, weight: .medium, design: .serif))
                .italic()
                .foregroundStyle(.secondary)
            Text("\u{8A00}\u{6240}\u{4E0D}\u{53CA}\u{5904}\u{FF0C}\u{7B19}\u{7BAB}\u{76F8}\u{7EE7}\u{3002}")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Text("— Hans Christian Andersen")
                .font(.caption2)
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