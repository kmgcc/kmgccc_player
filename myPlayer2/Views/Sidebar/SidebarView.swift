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
    @Environment(ImportEnrichmentService.self) private var importEnrichmentService
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var currentColorScheme

    @State private var showSettings = false
    @State private var showingPlaylistSheet = false
    @State private var deletionRequest: SidebarDeletionRequest?
    @State private var isHoveringPlaylists = false
    @State private var isArtistsExpanded = false
    @State private var isAlbumsExpanded = false

    @State private var isHoveringArtists = false
    @State private var isHoveringAlbums = false
    @State private var settingsRotateTrigger = 0
    @State private var appearanceRotateTrigger = 0

    var body: some View {
        VStack(spacing: 0) {
            if settings.showPlaybackSourceSwitcher {
                playbackSourceSwitcher
                    .padding(.horizontal, 14)
                    .padding(.top, 5)
                    .padding(.bottom, 12)
            } else {
                legacyAppHeader
                    .padding(.horizontal, 14)
                    .padding(.top, 5)
                    .padding(.bottom, 12)
            }

            // Main Library Link
            Button {
                libraryVM.currentSelection = .allSongs
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
                            Button(role: .destructive) {
                                deletionRequest = .playlist(playlist: playlist)
                            } label: {
                                Label(
                                    NSLocalizedString("edit.playlist.delete", comment: ""),
                                    systemImage: "trash"
                                )
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
                        ForEach(libraryVM.runtimeArtists) { artist in
                            Button {
                                handleSelection(.artist(artist.key))
                            } label: {
                                HStack {
                                    Text(artist.name)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    selectionFill(
                                        isSelected: currentSelection == .artist(artist.key))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                if let entry = libraryVM.artistEntry(for: artist) {
                                    Button(role: .destructive) {
                                        deletionRequest = .artist(
                                            entry: entry,
                                            trackCount: artist.trackCount
                                        )
                                    } label: {
                                        Label(
                                            "sidebar.delete_artist",
                                            systemImage: "trash"
                                        )
                                    }
                                }
                            }
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
                        ForEach(libraryVM.runtimeAlbums) { album in
                            Button {
                                handleSelection(.album(album.key))
                            } label: {
                                HStack {
                                    Text(album.name)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    selectionFill(
                                        isSelected: currentSelection == .album(album.key))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                if let entry = libraryVM.albumEntry(for: album) {
                                    Button(role: .destructive) {
                                        deletionRequest = .album(
                                            entry: entry,
                                            trackCount: album.trackCount
                                        )
                                    } label: {
                                        Label(
                                            "sidebar.delete_album",
                                            systemImage: "trash"
                                        )
                                    }
                                }
                            }
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

            if importEnrichmentService.hasOutstandingWork {
                sidebarEnrichmentStatus
                    .transition(.opacity)
            }

            Divider()

            // Bottom controls
            HStack(spacing: 8) {
                settingsButton
                appearanceSwitchButton
                fullscreenButton
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
            PlaylistEditSheet()
        }
        .alert(
            deletionRequest?.title ?? "",
            isPresented: Binding(
                get: { deletionRequest != nil },
                set: { if !$0 { deletionRequest = nil } }
            ),
            presenting: deletionRequest
        ) { request in
            Button(request.confirmActionTitle, role: .destructive) {
                confirmDeletion(request)
            }
            Button(NSLocalizedString("edit.track.cancel", comment: ""), role: .cancel) {
                deletionRequest = nil
            }
        } message: { request in
            Text(request.message)
        }
        .onChange(of: settings.enableSystemNowPlayingMode) { _, enabled in
            if !enabled, playbackCoordinator.activeSource == .systemNowPlaying {
                withAnimation(.snappy(duration: 0.18)) {
                    playbackCoordinator.setActiveSource(.local)
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: importEnrichmentService.hasOutstandingWork)
    }

    private var legacyAppHeader: some View {
        Button {
            uiState.showLibrary()
        } label: {
            Label(Constants.appName, systemImage: "music.pages.fill")
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.primary, themeStore.accentColor)
        }
        .buttonStyle(.plain)
    }

    private var playbackSourceSwitcher: some View {
        let metrics = PlaybackSourceSwitcherMetrics.self
        let availableSources: [PlaybackSource] = settings.enableSystemNowPlayingMode
            ? PlaybackSource.allCases
            : [.local, .appleMusic]

        return SlidingSelector(
            segments: availableSources,
            selection: Binding(
                get: { playbackCoordinator.activeSource },
                set: { source in
                    withAnimation(.snappy(duration: 0.18)) {
                        playbackCoordinator.setActiveSource(source)
                    }
                }
            ),
            animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
            hSpacing: 0,
            background: {
                Color.clear
            },
            knob: {
                Capsule(style: .continuous)
                    .fill(themeStore.accentColor.opacity(currentColorScheme == .dark ? 0.36 : 0.18))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(themeStore.accentColor.opacity(0.32), lineWidth: 1)
                    )
            },
            content: { source, isSelected in
                playbackSourceSegment(source, isSelected: isSelected)
            }
        )
        .frame(maxWidth: .infinity)
        .frame(height: metrics.knobHeight)
        .padding(metrics.knobInset)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(currentColorScheme == .dark ? 0.12 : 0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
        )
        .frame(maxWidth: .infinity)
        .frame(height: metrics.trayHeight)
        .help(LocalizedStringKey("playback.source.help"))
    }

    private func playbackSourceSegment(_ source: PlaybackSource, isSelected: Bool) -> some View {
        let title = LocalizedStringKey(source.localizedTitleKey)
        let foregroundColor = isSelected ? selectedPlaybackSourceTextColor : Color.secondary
        let isTwoSegmentMode = !settings.enableSystemNowPlayingMode
        let minWidth: CGFloat = {
            switch source {
            case .appleMusic:
                return isTwoSegmentMode ? 118 : 88
            case .local:
                return isTwoSegmentMode ? 58 : 46
            case .systemNowPlaying:
                return 46
            }
        }()

        return Text(title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.86)
            .foregroundStyle(foregroundColor)
            .frame(minWidth: minWidth, maxWidth: .infinity)
            .frame(height: PlaybackSourceSwitcherMetrics.knobHeight)
            .contentShape(Rectangle())
    }

    private var selectedPlaybackSourceTextColor: Color {
        currentColorScheme == .dark ? .primary : themeStore.accentColor
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

    private var fullscreenButton: some View {
        GlassIconButton(
            systemImage: "arrow.up.left.and.arrow.down.right",
            size: GlassStyleTokens.headerControlHeight,
            iconSize: 14,
            isPrimary: false,
            help: LocalizedStringKey("sidebar.fullscreen"),
            surfaceVariant: .sidebarBottom
        ) {
            FullscreenWindowManager.shared.showFullscreenWindow()
        }
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
            libraryVM.currentSelection = .allSongs
        case .playlist(let id):
            libraryVM.currentSelection = .playlist(id)
        case .artist(let key):
            libraryVM.currentSelection = .artist(key)
        case .album(let key):
            libraryVM.currentSelection = .album(key)
        }
        uiState.showLibrary()
    }

    private var currentSelection: SidebarSelection {
        // Use the explicit currentSelection from LibraryViewModel
        switch libraryVM.currentSelection {
        case .allSongs:
            return .allSongs
        case .playlist(let id):
            return .playlist(id)
        case .artist(let key):
            return .artist(key)
        case .album(let key):
            return .album(key)
        }
    }

    @ViewBuilder
    private func selectionFill(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? themeStore.selectionFill : Color.clear)
    }

    private var sidebarEnrichmentStatus: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.72)

            Text(importEnrichmentService.progress.sidebarText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func confirmDeletion(_ request: SidebarDeletionRequest) {
        deletionRequest = nil
        Task {
            switch request {
            case .playlist(let playlist):
                await libraryVM.deletePlaylist(playlist)
            case .artist(let entry, _):
                await libraryVM.deleteArtist(entry)
            case .album(let entry, _):
                await libraryVM.deleteAlbum(entry)
            }
        }
    }
}

// MARK: - Sidebar Selection

private enum SidebarSelection: Hashable {
    case allSongs
    case playlist(UUID)
    case artist(String)
    case album(String)
}

private enum SidebarDeletionRequest: Identifiable {
    case playlist(playlist: Playlist)
    case artist(entry: ArtistEntry, trackCount: Int)
    case album(entry: AlbumEntry, trackCount: Int)

    var id: String {
        switch self {
        case .playlist(let playlist):
            return "playlist-\(playlist.id.uuidString)"
        case .artist(let entry, _):
            return "artist-\(entry.id.uuidString)"
        case .album(let entry, _):
            return "album-\(entry.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .playlist:
            return NSLocalizedString("edit.playlist.delete_confirm_title", comment: "")
        case .artist:
            return NSLocalizedString("sidebar.delete_artist_confirm_title", comment: "")
        case .album:
            return NSLocalizedString("sidebar.delete_album_confirm_title", comment: "")
        }
    }

    var confirmActionTitle: String {
        switch self {
        case .playlist:
            return NSLocalizedString("edit.playlist.delete_confirm", comment: "")
        case .artist:
            return NSLocalizedString("sidebar.delete_artist", comment: "")
        case .album:
            return NSLocalizedString("sidebar.delete_album", comment: "")
        }
    }

    var message: String {
        switch self {
        case .playlist:
            return NSLocalizedString("edit.playlist.delete_desc", comment: "")
        case .artist(let entry, let trackCount):
            return String(
                format: NSLocalizedString("sidebar.delete_artist_confirm_message", comment: ""),
                entry.displayName,
                trackCount
            )
        case .album(let entry, let trackCount):
            return String(
                format: NSLocalizedString("sidebar.delete_album_confirm_message", comment: ""),
                entry.displayTitle,
                trackCount
            )
        }
    }
}

private enum PlaybackSourceSwitcherMetrics {
    static let trayHeight: CGFloat = 32
    static let knobInset: CGFloat = 3
    static let knobHeight: CGFloat = trayHeight - knobInset * 2
}

private struct SidebarWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = Constants.Layout.sidebarDefaultWidth

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Preview

#Preview("Sidebar") { @MainActor in
    let repository = StubLibraryRepository()
    let libraryVM = LibraryViewModel(repository: repository)
    let uiState = UIStateViewModel()

    NavigationSplitView {
        SidebarView()
            .environment(libraryVM)
            .environment(ImportEnrichmentService(repository: repository))
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
