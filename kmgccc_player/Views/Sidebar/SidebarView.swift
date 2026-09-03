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
import UniformTypeIdentifiers

/// Sidebar view for navigation and playlists.
/// IMPORTANT: Do NOT add .background(material) or NSVisualEffectView here!
/// The NavigationSplitView sidebar column automatically gets system Liquid Glass.
struct SidebarView: View {

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(ImportEnrichmentService.self) private var importEnrichmentService
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(LyricsViewModel.self) private var lyricsVM
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider
    @Environment(LibraryCacheServices.self) private var cacheServices
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var currentColorScheme
    @ObservedObject private var updateCoordinator = UpdateCoordinator.shared
    @ObservedObject private var crashReportService = CrashReportService.shared

    @State private var showSettings = false
    @State private var showCrashReportSettingsTip = false
    @State private var crashReportTipTask: Task<Void, Never>?
    @State private var showingPlaylistSheet = false
    @State private var deletionRequest: SidebarDeletionRequest?
    @State private var failedEnrichmentEditRequest: FailedEnrichmentEditRequest?
    @State private var editingArtistEntry: ArtistEntry?
    @State private var editingAlbumEntry: AlbumEntry?
    @State private var isHoveringPlaylists = false
    @State private var dropTargetPlaylistID: UUID?
    @State private var isPlaylistsExpanded = true
    @State private var isPlaylistHeaderDropTargeted = false
    @State private var playlistHeaderExpandTask: Task<Void, Never>?
    @State private var isArtistsExpanded = false
    @State private var isAlbumsExpanded = false

    @State private var isHoveringArtists = false
    @State private var isHoveringAlbums = false
    @State private var settingsRotateTrigger = 0
    @State private var appearanceRotateTrigger = 0
    @State private var scrollFadeState = ScrollEdgeFadeState()
    @State private var showingLibraryImportStatus = false

    private let scrollFadeHeight: CGFloat = 28

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

            primaryNavigation

            // Playlists List
            List {
                Section {
                    if isPlaylistsExpanded {
                        ForEach(libraryVM.sortedPlaylistsForDisplay()) { playlist in
                        Button {
                            handleSelection(.playlist(playlist.id))
                        } label: {
                            HStack(spacing: 9) {
                                SidebarPlaylistThumbnail(
                                    playlistID: playlist.id,
                                    refreshToken: libraryVM.refreshTrigger
                                )
                                Text(playlist.name)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                selectionFill(
                                    isSelected: currentSelection == .playlist(playlist.id))
                            )
                            .overlay {
                                if dropTargetPlaylistID == playlist.id {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(themeStore.accentColor, lineWidth: 1.5)
                                        .opacity(0.9)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onDrop(
                            of: [UTType.fileURL.identifier, UTType.url.identifier],
                            isTargeted: dropTargetBinding(for: playlist.id)
                        ) { providers in
                            acceptPlaylistDrop(providers, playlistID: playlist.id)
                        }
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button {
                                play(playlist)
                            } label: {
                                Label("播放该播放列表", systemImage: "play.fill")
                            }

                            Button {
                                Task { @MainActor in
                                    let count = await libraryVM.importToPlaylist(playlist)
                                    guard count > 0 else { return }
                                    uiState.showSidebarNotice("已导入 \(count) 首歌曲")
                                }
                            } label: {
                                Label("导入到当前播放列表", systemImage: "square.and.arrow.down")
                            }

                            Divider()

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
                    }
                } header: {
                    HStack {
                        Button {
                            setPlaylistsExpanded(!isPlaylistsExpanded)
                        } label: {
                            HStack(spacing: 5) {
                                Text("sidebar.playlists")
                                    .font(.caption.bold())
                                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                                Text("\(libraryVM.playlists.count)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor.opacity(0.65))
                                Image(systemName: "chevron.right")
                                    .font(.caption2.bold())
                                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                                    .rotationEffect(.degrees(isPlaylistsExpanded ? 90 : 0))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()

                        Button {
                            showingPlaylistSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
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
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [UTType.fileURL.identifier, UTType.url.identifier],
                        isTargeted: playlistHeaderDropTarget
                    ) { providers in
                        acceptPlaylistHeaderDrop(providers)
                    }
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
                            .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
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
                                .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
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
                                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold())
                                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
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
                            .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
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
                                .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
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
                                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold())
                                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
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
            .onScrollGeometryChange(for: ScrollEdgeFadeState.self) { geometry in
                ScrollEdgeFadeState(geometry: geometry, fadeHeight: scrollFadeHeight)
            } action: { _, newState in
                scrollFadeState = newState
            }
            .scrollEdgeFadeMask(scrollFadeState, fadeHeight: scrollFadeHeight)
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
        .onAppear {
            loadPlaylistsExpandedForActiveLibrary()
            ensureSelectedPlaylistGroupExpanded()
            scheduleCrashReportSettingsTipIfNeeded()
        }
        .onChange(of: appSession.activeLibraryBinding.context?.id) { _, _ in
            loadPlaylistsExpandedForActiveLibrary()
            ensureSelectedPlaylistGroupExpanded()
        }
        .onDisappear {
            crashReportTipTask?.cancel()
            crashReportTipTask = nil
            showCrashReportSettingsTip = false
            cancelPlaylistHeaderAutoExpand()
        }
        .onChange(of: crashReportService.isPromptFlowActive) { _, isActive in
            if isActive {
                crashReportTipTask?.cancel()
                showCrashReportSettingsTip = false
            } else {
                scheduleCrashReportSettingsTipIfNeeded()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(hasActiveLibrarySession: true)
                .environment(settings)
                .environment(libraryVM)
                .environment(playerVM)
                .environment(playbackCoordinator)
                .environment(lyricsVM)
                .environment(ledMeterProvider)
                .environment(cacheServices)
                .environmentObject(appSession)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $showingLibraryImportStatus) {
            LibraryImportStatusDialogView(
                reports: uiState.libraryImportFailureReports,
                tasks: appSession.activeLibraryTasks,
                onClear: { uiState.clearLibraryImportFailureReports() }
            )
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
        .animation(.snappy(duration: 0.2), value: uiState.sidebarNotice?.id)
        .sheet(item: $failedEnrichmentEditRequest) { request in
            // Reuses the exact multi-track metadata editor from the library
            // list so failed enrichment items can be fixed by hand.
            BatchTrackEditSheet(tracks: request.tracks)
        }
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

    private var primaryNavigation: some View {
        VStack(spacing: 2) {
            sidebarNavigationRow(
                title: "主页",
                systemImage: "house",
                selection: .home
            ) {
                uiState.clearHomeNavigationContext()
                libraryVM.selectOrResetCurrentSelection(.home)
                uiState.showLibrary()
            }

            sidebarNavigationRow(
                title: "sidebar.all_songs",
                systemImage: "music.note.list",
                selection: .allSongs
            ) {
                libraryVM.selectOrResetCurrentSelection(.allSongs)
                uiState.showLibrary()
            }

            if appSession.activeLibraryBinding.context?.mode == .referenced {
                sidebarNavigationRow(
                    title: "文件夹",
                    systemImage: "folder",
                    selection: .folders
                ) {
                    libraryVM.selectOrResetCurrentSelection(.folders)
                    uiState.showLibrary()
                }
            }

            sidebarNavigationRow(
                title: "播放历史",
                systemImage: "clock.arrow.circlepath",
                selection: .history
            ) {
                uiState.clearHomeNavigationContext()
                uiState.showPlaybackHistory()
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func sidebarNavigationRow(
        title: LocalizedStringKey,
        systemImage: String,
        selection: SidebarSelection,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 18, height: 18, alignment: .center)

                Text(title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
            .padding(.horizontal, 16)
            .frame(height: 32, alignment: .center)
            .background(
                selectionFill(
                    isSelected: currentSelection == selection,
                    shape: .capsule
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
    }

    private var updateSidebarProgress: SidebarTaskProgress? {
        switch updateCoordinator.state {
        case .checking(let manual):
            return SidebarTaskProgress(
                title: "正在检查更新",
                detail: manual ? "正在获取最新版本信息" : "后台检查进行中",
                fractionCompleted: nil,
                state: .running
            )
        case .downloading(let progress):
            return SidebarTaskProgress(
                title: "正在下载更新",
                detail: "下载完成后可重启安装",
                fractionCompleted: progress,
                state: .running
            )
        case .preparing(let progress):
            return SidebarTaskProgress(
                title: "正在准备更新",
                detail: "正在验证并解压安装包",
                fractionCompleted: progress,
                state: .running
            )
        case .installReplyPending:
            return SidebarTaskProgress(
                title: "正在准备退出",
                detail: "正在保存播放状态并关闭辅助进程",
                fractionCompleted: nil,
                state: .running
            )
        case .waitingForTermination(_, let retryInFlight):
            return SidebarTaskProgress(
                title: retryInFlight ? "正在再次退出" : "等待应用退出",
                detail: retryInFlight ? "正在请求安装程序继续更新" : "点击重试以再次退出并完成更新",
                fractionCompleted: nil,
                state: .running
            )
        case .installing:
            return SidebarTaskProgress(
                title: "正在安装更新",
                detail: "应用将退出并在完成后重新启动",
                fractionCompleted: nil,
                state: .running
            )
        case .failed(let failure):
            return SidebarTaskProgress(
                title: failure.title,
                detail: failure.message,
                fractionCompleted: nil,
                state: .failed
            )
        case .idle, .ready, .suppressed:
            return nil
        }
    }

    private var updateProgressDismissAction: (() -> Void)? {
        switch updateCoordinator.state {
        case .checking, .downloading:
            guard updateCoordinator.canCancelCurrentOperation else { return nil }
            return { updateCoordinator.cancelCurrentOperation() }
        case .failed:
            return { updateCoordinator.dismissFailure() }
        default:
            return nil
        }
    }

    private var updateProgressRetryAction: (() -> Void)? {
        if case .waitingForTermination(_, let retryInFlight) = updateCoordinator.state {
            return retryInFlight ? nil : { updateCoordinator.retryTerminatingApplication() }
        }
        guard case .failed = updateCoordinator.state else { return nil }
        return { updateCoordinator.retryFailedUpdate() }
    }

    private var hasSidebarTaskProgress: Bool {
        uiState.sidebarNotice != nil
            || updateSidebarProgress != nil
            || updateCoordinator.readyUpdate != nil
            || importEnrichmentService.hasOutstandingWork
            || importEnrichmentService.completionSummary != nil
            || activeLibraryImportTask != nil
            || !uiState.libraryImportFailureReports.isEmpty
    }

    private var sidebarTaskProgressStack: some View {
        VStack(spacing: 6) {
            if let notice = uiState.sidebarNotice {
                SidebarNoticeView(notice: notice) {
                    if activeLibraryImportTask != nil || !uiState.libraryImportFailureReports.isEmpty {
                        showingLibraryImportStatus = true
                    } else {
                        showSettings = true
                    }
                }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let progress = libraryImportSidebarProgress {
                Button {
                    showingLibraryImportStatus = true
                } label: {
                    SidebarTaskProgressView(progress: progress)
                }
                .buttonStyle(.plain)
                .help("点击查看导入状态")
                .transition(.opacity)
            }

            if let progress = updateSidebarProgress {
                SidebarTaskProgressView(
                    progress: progress,
                    onDismiss: updateProgressDismissAction,
                    onRetry: updateProgressRetryAction
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let readyUpdate = updateCoordinator.readyUpdate {
                SidebarUpdateReadyView(
                    update: readyUpdate,
                    onInstall: {
                        updateCoordinator.restartAndInstall()
                    },
                    onDismiss: {
                        updateCoordinator.dismissReadyUpdate()
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if importEnrichmentService.hasOutstandingWork {
                Button {
                    EnrichmentStatusDialogPresenter.present(service: importEnrichmentService)
                } label: {
                    SidebarTaskProgressView(progress: importEnrichmentSidebarProgress)
                }
                .buttonStyle(.plain)
                .help("点击查看每首歌曲的补全状态")
                .transition(.opacity)
            } else if let summary = importEnrichmentService.completionSummary {
                SidebarEnrichmentCompletionNotice(
                    summary: summary,
                    onShowFailures: { showFailedEnrichmentEditor(failedTrackIDs: summary.failedTrackIDs) },
                    onDismiss: { importEnrichmentService.dismissCompletionSummary() }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    private var activeLibraryImportTask: LibraryOperationTaskDescriptor? {
        appSession.activeLibraryTasks.reversed().first { task in
            !task.state.isTerminal
                && [.importFiles, .sourceScan, .ncmConversion, .enrichment].contains(task.kind)
        }
    }

    private var libraryImportSidebarProgress: SidebarTaskProgress? {
        if let task = activeLibraryImportTask {
            let title: String
            switch task.kind {
            case .sourceScan: title = "正在扫描来源"
            case .ncmConversion: title = "正在转换歌曲"
            case .enrichment: title = "正在补全信息"
            default: title = "正在导入歌曲"
            }
            return SidebarTaskProgress(
                title: title,
                detail: task.lastCheckpointLabel ?? "正在处理",
                fractionCompleted: nil,
                state: .running
            )
        }

        let failureCount = uiState.libraryImportFailureReports
            .flatMap(\.failures)
            .count
        guard failureCount > 0 else { return nil }
        return SidebarTaskProgress(
            title: "导入有失败",
            detail: "\(failureCount) 项需要查看",
            fractionCompleted: nil,
            state: .failed
        )
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
        .keyboardShortcut(",", modifiers: .command)
        .popover(isPresented: $showCrashReportSettingsTip, arrowEdge: .bottom) {
            CrashReportSettingsTipView(
                onOpenSettings: {
                    showCrashReportSettingsTip = false
                    AppVersionGate.shared.markFeatureTipDismissed(
                        featureKey: CrashReportFeatureTip.key
                    )
                    settingsRotateTrigger += 1
                    showSettings = true
                },
                onDismiss: {
                    showCrashReportSettingsTip = false
                }
            )
        }
    }

    private enum CrashReportFeatureTip {
        static let key = "dataSharing.automaticCrashReports"
        static let introducedBuild = AppBuild(8)
        static let maxDisplayCount = 2
    }

    private func scheduleCrashReportSettingsTipIfNeeded() {
        crashReportTipTask?.cancel()
        guard !crashReportService.isPromptFlowActive,
              !showSettings,
              !showingPlaylistSheet,
              !showCrashReportSettingsTip,
              AppVersionGate.shared.shouldShowFeatureTip(
                featureKey: CrashReportFeatureTip.key,
                introducedBuild: CrashReportFeatureTip.introducedBuild,
                maxDisplayCount: CrashReportFeatureTip.maxDisplayCount
              )
        else { return }

        crashReportTipTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled,
                  !crashReportService.isPromptFlowActive,
                  !showSettings,
                  !showingPlaylistSheet
            else { return }
            showCrashReportSettingsTip = true
            AppVersionGate.shared.recordFeatureTipDisplayed(
                featureKey: CrashReportFeatureTip.key
            )
        }
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
            libraryVM.selectOrResetCurrentSelection(.home)
        case .allSongs:
            libraryVM.selectOrResetCurrentSelection(.allSongs)
        case .folders:
            libraryVM.selectOrResetCurrentSelection(.folders)
        case .history:
            uiState.showPlaybackHistory()
            return
        case .allPlaylists:
            uiState.pushSelectionInHomeContext(.allPlaylists, libraryVM: libraryVM)
            return
        case .allAlbums:
            uiState.pushSelectionInHomeContext(.allAlbums, libraryVM: libraryVM)
            return
        case .allArtists:
            uiState.pushSelectionInHomeContext(.allArtists, libraryVM: libraryVM)
            return
        case .playlist(let id):
            libraryVM.selectOrResetCurrentSelection(.playlist(id))
        case .artist(let key):
            libraryVM.selectOrResetCurrentSelection(.artist(key))
        case .album(let key):
            libraryVM.selectOrResetCurrentSelection(.album(key))
        }
        uiState.showLibrary()
    }

    private func dropTargetBinding(for playlistID: UUID) -> Binding<Bool> {
        Binding(
            get: { dropTargetPlaylistID == playlistID },
            set: { isTargeted in
                if isTargeted {
                    dropTargetPlaylistID = playlistID
                } else if dropTargetPlaylistID == playlistID {
                    dropTargetPlaylistID = nil
                }
            }
        )
    }

    // MARK: - Playlist Group Collapse (spec 4.2)

    private var playlistsExpandedStorageKey: String {
        let libraryID = appSession.activeLibraryBinding.context?.id.uuidString ?? "no-library"
        return "sidebar.playlists.expanded.\(libraryID)"
    }

    private func loadPlaylistsExpandedForActiveLibrary() {
        let stored = UserDefaults.standard.object(forKey: playlistsExpandedStorageKey) as? Bool
        isPlaylistsExpanded = stored ?? true
    }

    private func setPlaylistsExpanded(_ expanded: Bool) {
        withAnimation(.snappy(duration: 0.18)) {
            isPlaylistsExpanded = expanded
        }
        UserDefaults.standard.set(expanded, forKey: playlistsExpandedStorageKey)
    }

    /// Spec 4.2: when window state restores a playlist selection, its group
    /// must auto-expand so the selection stays visible.
    private func ensureSelectedPlaylistGroupExpanded() {
        var restoredPlaylistID: UUID?
        if case .playlist(let id) = libraryVM.currentSelection {
            restoredPlaylistID = id
        }
        if restoredPlaylistID == nil,
           let stored = UserDefaults.standard.string(forKey: "lastSelectedPlaylistId"),
           let id = UUID(uuidString: stored),
           libraryVM.playlists.contains(where: { $0.id == id }) {
            restoredPlaylistID = id
        }
        guard restoredPlaylistID != nil, !isPlaylistsExpanded else { return }
        setPlaylistsExpanded(true)
    }

    private var playlistHeaderDropTarget: Binding<Bool> {
        Binding(
            get: { isPlaylistHeaderDropTargeted },
            set: { targeted in
                guard targeted != isPlaylistHeaderDropTargeted else { return }
                isPlaylistHeaderDropTargeted = targeted
                if targeted {
                    schedulePlaylistHeaderAutoExpand()
                } else {
                    cancelPlaylistHeaderAutoExpand()
                }
            }
        )
    }

    private func schedulePlaylistHeaderAutoExpand() {
        guard !isPlaylistsExpanded else { return }
        playlistHeaderExpandTask?.cancel()
        playlistHeaderExpandTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            setPlaylistsExpanded(true)
        }
    }

    private func cancelPlaylistHeaderAutoExpand() {
        playlistHeaderExpandTask?.cancel()
        playlistHeaderExpandTask = nil
    }

    /// Spec 4.2: dropping on the group title never picks a random playlist.
    /// The header accepts the drop so it cannot fall through to window
    /// import, then hints toward a concrete playlist row.
    private func acceptPlaylistHeaderDrop(_ providers: [NSItemProvider]) -> Bool {
        let hasPayload = providers.contains {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        guard hasPayload else { return false }
        uiState.showSidebarNotice("请将文件拖到具体的播放列表行以导入", style: .warning)
        return true
    }

    /// Finder supplies file URLs for both files and directories. Loading the
    /// providers before constructing the ImportContext keeps the playlist row
    /// as the fixed destination even if the user changes selection while the
    /// provider data is being delivered.
    private func acceptPlaylistDrop(
        _ providers: [NSItemProvider],
        playlistID: UUID
    ) -> Bool {
        guard providers.contains(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) else {
            return false
        }
        Task { @MainActor in
            let urls = await Self.urls(from: providers)
            guard !urls.isEmpty else { return }
            await libraryVM.importDroppedURLsToPlaylist(urls, playlistID: playlistID)
        }
        return true
    }

    private static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let typeIdentifier: String?
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                typeIdentifier = UTType.fileURL.identifier
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                typeIdentifier = UTType.url.identifier
            } else {
                typeIdentifier = nil
            }
            guard let typeIdentifier else { continue }
            // `loadItem` returns `NSSecureCoding?`, which is not Sendable and
            // cannot safely cross the continuation's async boundary under the
            // project's strict concurrency settings. A data representation is
            // sufficient for both file URLs and regular URLs and keeps the
            // provider callback at a Sendable boundary.
            let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            guard let data else { continue }
            if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                urls.append(url)
            } else if let string = String(data: data, encoding: .utf8),
                      let url = URL(string: string),
                      url.isFileURL {
                urls.append(url)
            }
        }
        return Array(Dictionary(uniqueKeysWithValues: urls.map { ($0.standardizedFileURL.path, $0) }).values)
    }

    private var currentSelection: SidebarSelection {
        if uiState.contentMode == .playbackHistory {
            return .history
        }

        // Use the explicit currentSelection from LibraryViewModel
        switch libraryVM.currentSelection {
        case .home:
            return .home
        case .allPlaylists:
            return .allPlaylists
        case .allAlbums:
            return .allAlbums
        case .allArtists:
            return .allArtists
        case .allSongs:
            return .allSongs
        case .folders:
            return .folders
        case .playlist(let id):
            return .playlist(id)
        case .artist(let key):
            return .artist(key)
        case .album(let key):
            return .album(key)
        }
    }

    private enum SidebarSelectionHighlightShape {
        case capsule
        case roundedRectangle
    }

    @ViewBuilder
    private func selectionFill(
        isSelected: Bool,
        shape: SidebarSelectionHighlightShape = .roundedRectangle
    ) -> some View {
        let fill = isSelected ? themeStore.selectionFill : Color.clear
        switch shape {
        case .capsule:
            Capsule(style: .continuous)
                .fill(fill)
        case .roundedRectangle:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fill)
        }
    }

    private func play(_ playlist: Playlist) {
        playbackCoordinator.playRandomTracks(
            playlist.tracks,
            libraryQueueSource: .librarySelection("sidebar-playlist-\(playlist.id.uuidString)")
        )
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

    private func showFailedEnrichmentEditor(failedTrackIDs: [UUID]) {
        let failedSet = Set(failedTrackIDs)
        let tracks = libraryVM.allTracks.filter { failedSet.contains($0.id) }
        guard !tracks.isEmpty else { return }
        failedEnrichmentEditRequest = FailedEnrichmentEditRequest(tracks: tracks)
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

private struct FailedEnrichmentEditRequest: Identifiable {
    let id = UUID()
    let tracks: [Track]
}

/// Persistent green notice shown after all background enrichment finishes.
/// Stays until the user dismisses it; taps open the multi-track metadata
/// editor prefilled with the failed songs when any part failed.
private struct SidebarEnrichmentCompletionNotice: View {
    let summary: ImportEnrichmentCompletionSummary
    let onShowFailures: () -> Void
    let onDismiss: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        // Title row and action row stack vertically — the sidebar is too
        // narrow to fit icon + title + action + close on one line.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.green)

                Text("歌曲信息补全完毕")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                .help("关闭")
            }

            if summary.failedCount > 0 {
                Button("查看 \(summary.failedCount) 首失败") {
                    onShowFailures()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(themeStore.accentColor)
                .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.green.opacity(0.25), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if summary.failedCount > 0 {
                onShowFailures()
            }
        }
    }
}

private enum SidebarSelection: Hashable {
    case home
    case allSongs
    case folders
    case history
    case allPlaylists
    case allAlbums
    case allArtists
    case playlist(UUID)
    case artist(String)
    case album(String)
}

private struct SidebarPlaylistThumbnail: View {
    let playlistID: UUID
    let refreshToken: Int

    @State private var image: NSImage?
    @State private var artworkChangeNonce = 0
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(LibraryCacheServices.self) private var cacheServices

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
        .task(id: taskIdentity) {
            await loadArtwork()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistArtworkDidChange)) { notification in
            guard let changedID = notification.userInfo?["playlistID"] as? UUID,
                  changedID == playlistID
            else { return }
            artworkChangeNonce += 1
        }
    }

    private var taskIdentity: String {
        let revision = libraryVM.playlistArtworkRevision(playlistID: playlistID) ?? "none"
        return "\(playlistID.uuidString)-\(refreshToken)-\(artworkChangeNonce)-\(revision)"
    }

    private func loadArtwork() async {
        guard let request = await Self.thumbnailRequest(
            playlistID: playlistID,
            pixelSide: pixelSide,
            paths: libraryVM.libraryPaths
        ) else {
            image = nil
            return
        }
        image = await cacheServices.playlistArtworkPipeline.load(request)
    }

    private static func thumbnailRequest(
        playlistID: UUID,
        pixelSide: CGFloat,
        paths: LibraryPaths
    ) async -> PlaylistArtworkRequest? {
        await Task.detached(priority: .utility) {
            makeThumbnailRequest(
                playlistID: playlistID,
                pixelSide: pixelSide,
                paths: paths
            )
        }.value
    }

    private nonisolated static func makeThumbnailRequest(
        playlistID: UUID,
        pixelSide: CGFloat,
        paths: LibraryPaths
    ) -> PlaylistArtworkRequest? {
        guard let sidecar = loadPlaylistSidecar(
            playlistID: playlistID,
            paths: paths
        ) else {
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

        guard let fileURL = paths.playlistAssetURL(fileName: fileName) else { return nil }
        let revision = sidecar.artworkRevision ?? fileName
        return PlaylistArtworkRequest(
            sourceIdentity: "sidebar-playlist-\(playlistID.uuidString)-\(revision)",
            variant: .rowHigh,
            artworkData: nil,
            fileURL: fileURL,
            pixelSize: CGSize(width: pixelSide, height: pixelSide)
        )
    }

    private nonisolated static func loadPlaylistSidecar(
        playlistID: UUID,
        paths: LibraryPaths
    ) -> PlaylistSidecar? {
        let url = paths.playlistURL(for: playlistID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PlaylistSidecar.self, from: data)
    }
}

private struct SidebarNoticeView: View {
    let notice: SidebarNotice
    let onAction: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.style == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(notice.style == .warning ? Color.orange : themeStore.accentColor)

            Text(notice.message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if let actionTitle = notice.actionTitle {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(themeStore.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(themeStore.appForegroundPalette.primaryColor.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(themeStore.appForegroundPalette.secondaryColor.opacity(0.12), lineWidth: 0.5)
        )
    }
}

private struct SidebarUpdateReadyView: View {
    let update: UpdateReadyMetadata
    let onInstall: () -> Void
    let onDismiss: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(themeStore.accentColor)

                Text("新版本 \(update.version) 已准备好")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                .help("删除并忽略此版本")
            }

            Text("已在后台安全下载")
                .font(.caption)
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)

            Button("重启更新", action: onInstall)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(themeStore.accentColor)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(themeStore.appForegroundPalette.primaryColor.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    themeStore.appForegroundPalette.secondaryColor.opacity(0.12),
                    lineWidth: 0.5
                )
        )
    }
}

private struct SidebarTaskProgressView: View {
    let progress: SidebarTaskProgress
    let onDismiss: (() -> Void)?
    let onRetry: (() -> Void)?

    @EnvironmentObject private var themeStore: ThemeStore

    init(
        progress: SidebarTaskProgress,
        onDismiss: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil
    ) {
        self.progress = progress
        self.onDismiss = onDismiss
        self.onRetry = onRetry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon

                Text(progress.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let percentageText = progress.percentageText {
                    Text(percentageText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                }

                if let onRetry {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(themeStore.accentColor)
                    .help("重新检查更新")
                }

                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 18, height: 18)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
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
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(themeStore.appForegroundPalette.primaryColor.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(themeStore.appForegroundPalette.secondaryColor.opacity(0.12), lineWidth: 0.5)
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
                    .tint(themeStore.accentColor)
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
    let libraryVM = LibraryViewModel.preview(repository: repository)
    let uiState = UIStateViewModel()
    let cacheServices = LibraryCacheServices.preview

    NavigationSplitView {
        SidebarView()
            .environment(libraryVM)
            .environment(ImportEnrichmentService(
                repository: repository,
                qqMusicCoverService: cacheServices.qqMusicCoverService,
                artistArtworkProviderCoordinator: cacheServices.artistArtworkProviderCoordinator,
                lyricsSearchCoordinator: cacheServices.lyricsSearchCoordinator,
                amllDBService: cacheServices.amllDBService
            ))
            .environment(cacheServices)
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
