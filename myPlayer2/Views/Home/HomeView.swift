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

    @State private var homeVM = HomeViewModel()

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
        }
        .onChange(of: libraryVM.refreshTrigger) { _, _ in
            homeVM.refresh(from: libraryVM)
        }
    }

    private var scrollContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 36) {
                if let heroTrack = homeVM.heroTrack {
                    HomeHeroView(track: heroTrack)
                }

                if !homeVM.albums.isEmpty {
                    HomeAlbumsSection(albums: homeVM.albums)
                }

                if !homeVM.artists.isEmpty {
                    HomeArtistsSection(artists: homeVM.artists)
                }

                if !homeVM.playlists.isEmpty {
                    HomePlaylistsSection(playlists: homeVM.playlists)
                }

                HomeInsightsSection(homeVM: homeVM)

                footer
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
    }

    private var emptyLibraryView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.house")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("home.empty_library", comment: "Your library is empty"))
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("home.empty_library_hint", comment: "Import some music to get started"))
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
