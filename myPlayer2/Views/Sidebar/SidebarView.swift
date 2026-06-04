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
import AppKit
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
    @ObservedObject private var updateDownloadManager = UpdatePackageDownloadManager.shared

    @State private var showSettings = false
    @State private var showingPlaylistSheet = false
    @State private var deletionRequest: SidebarDeletionRequest?
    @State private var editingArtistEntry: ArtistEntry?
    @State private var editingAlbumEntry: AlbumEntry?
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
                    .background(SourceSwitchAnchorProbe())
                    .padding(.horizontal, 14)
                    .padding(.top, 5)
                    .padding(.bottom, 12)
            } else {
                legacyAppHeader
                    .padding(.horizontal, 14)
                    .padding(.top, 5)
                    .padding(.bottom, 12)
            }

            // Home Link
            Button {
                uiState.clearHomeNavigationContext()
                libraryVM.currentSelection = .home
                uiState.showLibrary()
            } label: {
                HStack {
                    Label("主页", systemImage: "house")
                    Spacer()
                }
                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.primary))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    selectionFill(isSelected: currentSelection == .home)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 4)

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
                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.primary))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    selectionFill(isSelected: currentSelection == .allSongs)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.bottom, 16)

            // Playlists List
            List {
                Section {
                    ForEach(libraryVM.playlists) { playlist in
                        Button {
                            handleSelection(.playlist(playlist.id))
                        } label: {
                            HStack(spacing: 9) {
                                SidebarPlaylistThumbnail(playlistID: playlist.id)
                                Text(playlist.name)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.primary))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
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
                            .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
                        Spacer()

                        Button {
                            showingPlaylistSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
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
                        Button {
                            handleSelection(.allArtists)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "person.2")
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(width: 18, height: 18)
                                Text("查看全部艺人")
                                    .lineLimit(1)
                                Spacer()
                            }
                            .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.primary))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                selectionFill(isSelected: currentSelection == .allArtists)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .listRowBackground(Color.clear)

                        ForEach(libraryVM.runtimeArtists) { artist in
                            Button {
                                handleSelection(.artist(artist.key))
                            } label: {
                                HStack {
                                    Text(artist.name)
                                    Spacer()
                                }
                                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.primary))
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
                                    Button {
                                        editingArtistEntry = entry
                                    } label: {
                                        Label("编辑艺人", systemImage: "info.circle")
                                    }
                                    Divider()
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
                                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold())
                                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
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
                        Button {
                            handleSelection(.allAlbums)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.stack")
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(width: 18, height: 18)
                                Text("查看全部专辑")
                                    .lineLimit(1)
                                Spacer()
                            }
                            .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.primary))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                selectionFill(isSelected: currentSelection == .allAlbums)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .listRowBackground(Color.clear)

                        ForEach(libraryVM.runtimeAlbums) { album in
                            Button {
                                handleSelection(.album(album.key))
                            } label: {
                                HStack {
                                    Text(album.name)
                                    Spacer()
                                }
                                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.primary))
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
                                    Button {
                                        editingAlbumEntry = entry
                                    } label: {
                                        Label("编辑专辑", systemImage: "info.circle")
                                    }
                                    Divider()
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
                                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold())
                                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
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

            sidebarTaskProgressStack
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, hasSidebarTaskProgress ? 8 : 0)

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
        .sheet(item: $editingArtistEntry) { entry in
            ArtistInfoEditSheet(entry: entry) {}
                .presentationSizing(.page)
        }
        .sheet(item: $editingAlbumEntry) { entry in
            AlbumInfoEditSheet(entry: entry) {}
                .presentationSizing(.page)
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

    private var hasSidebarTaskProgress: Bool {
        updateDownloadManager.sidebarProgress != nil || importEnrichmentService.hasOutstandingWork
    }

    private var sidebarTaskProgressStack: some View {
        VStack(spacing: 6) {
            if let updateProgress = updateDownloadManager.sidebarProgress {
                SidebarTaskProgressView(
                    progress: updateProgress,
                    onDismiss: updateProgressDismissAction(for: updateProgress)
                )
                .transition(.opacity)
            }

            if importEnrichmentService.hasOutstandingWork {
                SidebarTaskProgressView(progress: importEnrichmentSidebarProgress)
                    .transition(.opacity)
            }
        }
    }

    private func updateProgressDismissAction(for progress: SidebarTaskProgress) -> (() -> Void)? {
        guard progress.state != .running else { return nil }
        return {
            updateDownloadManager.dismissSidebarProgress()
        }
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
                return isTwoSegmentMode ? 80 : 88
            case .local:
                return isTwoSegmentMode ? 80 : 46
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
        uiState.clearHomeNavigationContext()
        switch item {
        case .home:
            libraryVM.currentSelection = .home
        case .allSongs:
            libraryVM.currentSelection = .allSongs
        case .allAlbums:
            uiState.pushSelectionInHomeContext(.allAlbums, libraryVM: libraryVM)
            return
        case .allArtists:
            uiState.pushSelectionInHomeContext(.allArtists, libraryVM: libraryVM)
            return
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
        case .home:
            return .home
        case .allAlbums:
            return .allAlbums
        case .allArtists:
            return .allArtists
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
        Capsule(style: .continuous)
            .fill(isSelected ? themeStore.selectionFill : Color.clear)
    }

    private var importEnrichmentSidebarProgress: SidebarTaskProgress {
        let progress = importEnrichmentService.progress
        let fraction = progress.totalEnqueued > 0
            ? Double(progress.completedCount) / Double(progress.totalEnqueued)
            : nil
        return SidebarTaskProgress(
            title: "正在补全导入内容",
            detail: progress.sidebarText,
            fractionCompleted: fraction,
            state: .running
        )
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
    case home
    case allSongs
    case allAlbums
    case allArtists
    case playlist(UUID)
    case artist(String)
    case album(String)
}

private struct SidebarPlaylistThumbnail: View {
    let playlistID: UUID

    @State private var image: NSImage?

    private let side: CGFloat = 24
    private var pixelSide: CGFloat {
        side * max(1, NSScreen.main?.backingScaleFactor ?? 2)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "music.note.list")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: side, height: side)
            }
        }
        .frame(width: side, height: side)
        .task(id: playlistID) {
            await loadArtwork()
        }
    }

    private func loadArtwork() async {
        guard let request = await Self.thumbnailRequest(
            playlistID: playlistID,
            pixelSide: pixelSide
        ) else {
            image = nil
            return
        }
        image = await PlaylistArtworkPipeline.shared.load(request)
    }

    private static func thumbnailRequest(
        playlistID: UUID,
        pixelSide: CGFloat
    ) async -> PlaylistArtworkRequest? {
        await Task.detached(priority: .utility) {
            makeThumbnailRequest(playlistID: playlistID, pixelSide: pixelSide)
        }.value
    }

    private nonisolated static func makeThumbnailRequest(
        playlistID: UUID,
        pixelSide: CGFloat
    ) -> PlaylistArtworkRequest? {
        guard let sidecar = loadPlaylistSidecar(playlistID: playlistID) else {
            return nil
        }

        let fileName: String?
        switch sidecar.headerArtworkSource {
        case .some(.generated):
            fileName = sidecar.generatedHeaderArtworkFileName ?? sidecar.customHeaderArtworkFileName
        case .some(.custom), .some(.none), nil:
            fileName = sidecar.customHeaderArtworkFileName ?? sidecar.generatedHeaderArtworkFileName
        }
        guard let fileName, !fileName.isEmpty else { return nil }

        let fileURL = LocalLibraryPaths.playlistsRootURL.appendingPathComponent(fileName)
        let revision = sidecar.artworkRevision ?? fileName
        return PlaylistArtworkRequest(
            sourceIdentity: "sidebar-playlist-\(playlistID.uuidString)-\(revision)",
            variant: .rowHigh,
            artworkData: nil,
            fileURL: fileURL,
            pixelSize: CGSize(width: pixelSide, height: pixelSide)
        )
    }

    private nonisolated static func loadPlaylistSidecar(playlistID: UUID) -> PlaylistSidecar? {
        let url = LocalLibraryPaths.playlistURL(for: playlistID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PlaylistSidecar.self, from: data)
    }
}

private struct SidebarTaskProgressView: View {
    let progress: SidebarTaskProgress
    let onDismiss: (() -> Void)?

    @EnvironmentObject private var themeStore: ThemeStore

    init(progress: SidebarTaskProgress, onDismiss: (() -> Void)? = nil) {
        self.progress = progress
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon

                Text(progress.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.primary))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let percentageText = progress.percentageText {
                    Text(percentageText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
                }

                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 18, height: 18)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
                    .help("关闭")
                }
            }

            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(themeStore.accentColor)
            }

            Text(progress.detail)
                .font(.caption)
                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: themeStore.appForegroundPalette.primary).opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: themeStore.appForegroundPalette.secondary).opacity(0.12), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch progress.state {
        case .running:
            if progress.fractionCompleted == nil {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(themeStore.accentColor)
            }
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
        case .reminder:
            Image(systemName: "bell.badge")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(themeStore.accentColor)
        }
    }
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
