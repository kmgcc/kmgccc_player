//
//  SidebarView.swift
//  myPlayer2
//
//  kmgccc_player - Sidebar View
//  NO custom blur/material - let macOS 26 system render Liquid Glass.
//  Supports:
//  - New Playlist creation (creates and selects immediately)
//  - Playlist selection
//  - Settings access
//

import Observation
import SwiftUI

/// Sidebar view for navigation and playlists.
/// IMPORTANT: Do NOT add .background(material) or NSVisualEffectView here!
/// The NavigationSplitView sidebar column automatically gets system Liquid Glass.
struct SidebarView: View {

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var currentColorScheme

    @State private var showSettings = false
    @State private var showingPlaylistSheet = false
    @State private var playlistToEdit: Playlist?  // nil = create new
    @State private var isHoveringPlaylists = false
    @State private var isArtistsExpanded = false
    @State private var isAlbumsExpanded = false

    @State private var isHoveringArtists = false
    @State private var isHoveringAlbums = false
    @State private var settingsRotateTrigger = 0
    @State private var appearanceRotateTrigger = 0

    var body: some View {
        VStack(spacing: 0) {
            // App Header
            Button {
                uiState.showLibrary()
            } label: {
                Label(Constants.appName, systemImage: "music.pages.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        .primary, themeStore.accentColor
                    )
            }
            .buttonStyle(.plain)

            // Main Library Link
            Button {
                libraryVM.selectPlaylist(nil)
                uiState.showLibrary()
            } label: {
                HStack {
                    Label(
                        "sidebar.all_songs",
                        systemImage: "music.note.list")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    selectionFill(isSelected: currentSelection == .allSongs)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 16)

            // Playlists List
            List {
                Section {
                    ForEach(libraryVM.playlists) { playlist in
                        Button {
                            handleSelection(.playlist(playlist.id))
                        } label: {
                            HStack {
                                Label(playlist.name, systemImage: "music.note.list")
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                selectionFill(
                                    isSelected: currentSelection == .playlist(playlist.id))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button {
                                playlistToEdit = playlist
                                showingPlaylistSheet = true
                            } label: {
                                Label(
                                    "sidebar.edit_playlist",
                                    systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                Task {
                                    await libraryVM.deletePlaylist(playlist)
                                }
                            } label: {
                                Label(
                                    "sidebar.delete_playlist",
                                    systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("sidebar.playlists")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()

                        Button {
                            playlistToEdit = nil
                            showingPlaylistSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 18)
                                .background(.secondary.opacity(0.1))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .opacity(isHoveringPlaylists ? 1 : 0)
                        .allowsHitTesting(isHoveringPlaylists)
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }

                // Artists Section
                Section {
                    if isArtistsExpanded {
                        ForEach(libraryVM.uniqueArtists, id: \.self) { artist in
                            Button {
                                handleSelection(.artist(artist))
                            } label: {
                                HStack {
                                    Text(artist)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    selectionFill(
                                        isSelected: currentSelection == .artist(artist))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                            .listRowBackground(Color.clear)
                        }
                    }
                } header: {
                    Button {
                        withAnimation {
                            isArtistsExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Text("sidebar.artists")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isArtistsExpanded ? 90 : 0))
                                .opacity(isHoveringArtists ? 1 : 0)
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringArtists = $0 }
                }

                // Albums Section
                Section {
                    if isAlbumsExpanded {
                        ForEach(libraryVM.uniqueAlbums, id: \.self) { album in
                            Button {
                                handleSelection(.album(album))
                            } label: {
                                HStack {
                                    Text(album)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    selectionFill(
                                        isSelected: currentSelection == .album(album))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                            .listRowBackground(Color.clear)
                        }
                    }
                } header: {
                    Button {
                        withAnimation {
                            isAlbumsExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Text("sidebar.albums")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isAlbumsExpanded ? 90 : 0))
                                .opacity(isHoveringAlbums ? 1 : 0)
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringAlbums = $0 }
                }
            }
            .listStyle(.sidebar)
            .onHover { hovering in
                isHoveringPlaylists = hovering
            }

            Divider()

            // Bottom controls
            HStack(spacing: 8) {
                settingsButton
                appearanceSwitchButton
                Spacer(minLength: 0)
            }
            .tint(themeStore.accentColor)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: SidebarWidthPreferenceKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(SidebarWidthPreferenceKey.self) { width in
            uiState.updateSidebarWidth(width)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $showingPlaylistSheet) {
            PlaylistEditSheet(playlist: playlistToEdit)
        }
    }

    private var settingsButton: some View {
        GlassIconButton(
            systemImage: "gear",
            size: GlassStyleTokens.headerControlHeight,
            iconSize: 14,
            isPrimary: false,
            help: LocalizedStringKey("sidebar.settings"),
            surfaceVariant: .sidebarBottom
        ) {
            settingsRotateTrigger += 1
            showSettings = true
        }
        .symbolEffect(.rotate, value: settingsRotateTrigger)
    }

    private var appearanceSwitchButton: some View {
        let effectiveManualMode: AppSettings.ManualAppearance = {
            if settings.followSystemAppearance {
                return currentColorScheme == .dark ? .dark : .light
            }
            return settings.manualAppearance
        }()
        let icon: String = {
            effectiveManualMode == .dark ? "moon" : "sun.max"
        }()

        let helpText: LocalizedStringKey = {
            effectiveManualMode == .dark ? "sidebar.appearance_dark" : "sidebar.appearance_light"
        }()

        return GlassIconButton(
            systemImage: icon,
            size: GlassStyleTokens.headerControlHeight,
            iconSize: 14,
            isPrimary: true,
            help: helpText,
            surfaceVariant: .sidebarBottom
        ) {
            let target = nextAppearanceTarget()
            if target == .light {
                appearanceRotateTrigger += 1
            }
            cycleAppearance(to: target)
        }
        .symbolEffect(.rotate, value: appearanceRotateTrigger)
        .contentTransition(
            .symbolEffect(.replace.magic(fallback: .offUp.byLayer), options: .nonRepeating)
        )
        .animation(.snappy(duration: 0.24), value: icon)
    }

    private func cycleAppearance(to target: AppSettings.ManualAppearance) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            if settings.followSystemAppearance {
                settings.followSystemAppearance = false
            }
            settings.manualAppearance = target
        }
    }

    private func nextAppearanceTarget() -> AppSettings.ManualAppearance {
        let currentManual: AppSettings.ManualAppearance = {
            if settings.followSystemAppearance {
                return currentColorScheme == .dark ? .dark : .light
            }
            return settings.manualAppearance
        }()
        return currentManual == .dark ? .light : .dark
    }

    private func handleSelection(_ item: SidebarSelection) {
        switch item {
        case .allSongs:
            libraryVM.selectPlaylist(nil)
        case .playlist(let id):
            if let playlist = libraryVM.playlists.first(where: { $0.id == id }) {
                libraryVM.selectPlaylist(playlist)
            }
        case .artist(let name):
            libraryVM.selectArtist(name)
        case .album(let name):
            libraryVM.selectAlbum(name)
        }
        uiState.showLibrary()
    }

    private var currentSelection: SidebarSelection {
        if let id = libraryVM.selectedPlaylistId {
            return .playlist(id)
        } else if let artist = libraryVM.selectedArtist {
            return .artist(artist)
        } else if let album = libraryVM.selectedAlbum {
            return .album(album)
        }
        return .allSongs
    }

    @ViewBuilder
    private func selectionFill(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? themeStore.selectionFill : Color.clear)
    }
}

// MARK: - Sidebar Selection

private enum SidebarSelection: Hashable {
    case allSongs
    case playlist(UUID)
    case artist(String)
    case album(String)
}

private struct SidebarWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = Constants.Layout.sidebarDefaultWidth

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Preview

#Preview("Sidebar") {
    let repository = StubLibraryRepository()
    let libraryVM = LibraryViewModel(repository: repository)
    let uiState = UIStateViewModel()

    NavigationSplitView {
        SidebarView()
            .environment(libraryVM)
            .environment(uiState)
            .environmentObject(ThemeStore.shared)
    } detail: {
        Text("Detail")
    }
    .frame(width: 600, height: 500)
    .task {
        await libraryVM.load()
    }
}
