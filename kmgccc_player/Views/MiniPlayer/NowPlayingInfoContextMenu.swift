//
//  NowPlayingInfoContextMenu.swift
//  myPlayer2
//
//  Shared context menu for mini player now-playing metadata actions.
//

import AppKit
import SwiftUI

struct TrackDeletionConfirmationRequest: Identifiable {
    let tracks: [Track]
    let id = UUID()

    var message: String {
        if tracks.count == 1, let track = tracks.first {
            return String(
                format: NSLocalizedString("context.delete_track_confirm_message", comment: ""),
                track.title
            )
        }

        return String(
            format: NSLocalizedString("context.delete_tracks_confirm_message", comment: ""),
            tracks.count
        )
    }
}

extension View {
    func trackDeletionConfirmation(
        item: Binding<TrackDeletionConfirmationRequest?>,
        onConfirm: @escaping ([Track]) -> Void
    ) -> some View {
        alert(
            NSLocalizedString("context.delete_track_confirm_title", comment: ""),
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            presenting: item.wrappedValue
        ) { request in
            Button(
                NSLocalizedString("context.delete_confirm", comment: ""),
                role: .destructive
            ) {
                item.wrappedValue = nil
                onConfirm(request.tracks)
            }
            Button(
                NSLocalizedString("edit.track.cancel", comment: ""),
                role: .cancel
            ) {
                item.wrappedValue = nil
            }
        } message: { request in
            Text(request.message)
        }
    }
}

struct TrackActionMenuContent: View {
    let track: Track
    var canSelectMultiple = false
    var selectedPlaylistID: UUID?
    var onSelectMultiple: (() -> Void)?
    let onPlay: () -> Void
    var onPlayNext: (() -> Int)?
    let onEditTrack: (Track) -> Void
    let onDeleteFromLibraryRequest: (Track) -> Void
    var onRemoveFromCurrentPlaylist: ((Track) -> Void)?
    var onRelinkLocation: ((Track) -> Void)?
    var showsPlay: Bool = true
    var showsNavigation: Bool = true
    var showsDeleteFromLibrary: Bool = true
    var diagnosticSurface: String = "TrackContextMenu"

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState

    init(
        track: Track,
        canSelectMultiple: Bool = false,
        selectedPlaylistID: UUID? = nil,
        onSelectMultiple: (() -> Void)? = nil,
        onPlay: @escaping () -> Void,
        onPlayNext: (() -> Int)? = nil,
        onEditTrack: @escaping (Track) -> Void,
        onDeleteFromLibraryRequest: @escaping (Track) -> Void,
        onRemoveFromCurrentPlaylist: ((Track) -> Void)? = nil,
        onRelinkLocation: ((Track) -> Void)? = nil,
        showsPlay: Bool = true,
        showsNavigation: Bool = true,
        showsDeleteFromLibrary: Bool = true,
        diagnosticSurface: String = "TrackContextMenu"
    ) {
        let token = FirstUseHitchDiagnostics.begin(
            "TrackActionMenuContent.init",
            detail: "surface=\(diagnosticSurface), track=\(FirstUseHitchDiagnostics.trackIDPrefix(track.id))"
        )
        FirstUseHitchDiagnostics.end(token)

        self.track = track
        self.canSelectMultiple = canSelectMultiple
        self.selectedPlaylistID = selectedPlaylistID
        self.onSelectMultiple = onSelectMultiple
        self.onPlay = onPlay
        self.onPlayNext = onPlayNext
        self.onEditTrack = onEditTrack
        self.onDeleteFromLibraryRequest = onDeleteFromLibraryRequest
        self.onRemoveFromCurrentPlaylist = onRemoveFromCurrentPlaylist
        self.onRelinkLocation = onRelinkLocation
        self.showsPlay = showsPlay
        self.showsNavigation = showsNavigation
        self.showsDeleteFromLibrary = showsDeleteFromLibrary
        self.diagnosticSurface = diagnosticSurface
    }

    var body: some View {
        FirstUseHitchDiagnostics.measure(
            "TrackActionMenuContent.body",
            detail: "surface=\(diagnosticSurface), track=\(trackIDPrefix), playlists=\(libraryVM.playlists.count)"
        ) {
            menuBody
        }
    }

    @ViewBuilder
    private var menuBody: some View {
        if !track.availability.isPlayable, let onRelinkLocation {
            Button {
                invokeAction("relinkLocation") {
                    onRelinkLocation(track)
                }
            } label: {
                Label("连接的位置…", systemImage: "link")
            }

            Divider()
        }

        if canSelectMultiple, let onSelectMultiple {
            Button {
                invokeAction("selectMultiple") {
                    onSelectMultiple()
                }
            } label: {
                Label("多选歌曲…", systemImage: "checkmark.circle")
            }

            Divider()
        }

        if showsPlay {
            Button {
                invokeAction("play") {
                    onPlay()
                }
            } label: {
                Label("播放", systemImage: "play")
            }

            if let onPlayNext {
                Button {
                    invokeAction("playNext") {
                        if onPlayNext() > 0 {
                            uiState.showSidebarNotice("已加入下一首")
                        }
                    }
                } label: {
                    Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
            }

            Divider()
        }

        let isManuallyLiked = currentManualLikeState == .liked
        Button {
            let nextState: ManualLikeState = isManuallyLiked ? .none : .liked
            invokeAction(isManuallyLiked ? "unlike" : "like") {
                Task {
                    await libraryVM.setManualLikeState(nextState, for: track)
                }
            }
        } label: {
            if isManuallyLiked {
                Label("取消喜欢", systemImage: "heart.slash")
            } else {
                Label("喜欢", systemImage: "heart")
            }
        }

        Divider()

        Menu {
            playlistSubmenuContent
        } label: {
            Label("添加到播放列表...", systemImage: "plus.circle")
        }
        .id("single_add_to_playlist_\(libraryVM.playlists.count)")

        if let onRemoveFromCurrentPlaylist {
            Button {
                invokeAction("removeFromCurrentPlaylist") {
                    onRemoveFromCurrentPlaylist(track)
                }
            } label: {
                Label("从当前播放列表移除", systemImage: "minus.circle")
            }
        }

        Divider()

        Button {
            invokeAction("editTrack") {
                onEditTrack(track)
            }
        } label: {
            Label("编辑歌曲信息", systemImage: "info.circle")
        }

        if canRelocateAudioFile {
            Button {
                TrackAudioRelocationAction(
                    libraryVM: libraryVM,
                    uiState: uiState
                ).run(for: track)
            } label: {
                Label("重新定位音频文件…", systemImage: "waveform.badge.magnifyingglass")
            }
        }

        if showsNavigation && shouldShowArtistNavigation {
            Button {
                invokeAction("navigateArtist") {
                    libraryVM.navigateToArtist(for: track, uiState: uiState)
                }
            } label: {
                Label("查看艺人", systemImage: "person.crop.circle")
            }
        }

        if showsNavigation && shouldShowAlbumNavigation {
            Button {
                invokeAction("navigateAlbum") {
                    libraryVM.navigateToAlbum(for: track, uiState: uiState)
                }
            } label: {
                Label("查看专辑", systemImage: "rectangle.stack")
            }
        }

        if showsDeleteFromLibrary {
            Divider()

            Button(role: .destructive) {
                let token = ContextMenuDiagnostics.beginActionInvoke(
                    surface: diagnosticSurface,
                    detail: "action=deleteTrack, track=\(trackIDPrefix)"
                )
                onDeleteFromLibraryRequest(track)
                ContextMenuDiagnostics.end(token)
            } label: {
                Label("从资料库删除", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var playlistSubmenuContent: some View {
        let detail = "track=\(trackIDPrefix), playlists=\(libraryVM.playlists.count)"
        let submenuToken = ContextMenuDiagnostics.beginSubmenuBuild(
            surface: diagnosticSurface,
            detail: detail
        )
        let playlistToken = FirstUseHitchDiagnostics.begin(
            "PlaylistActionSubmenu.build",
            detail: "surface=\(diagnosticSurface), \(detail)"
        )
        let hoverToken = FirstUseHitchDiagnostics.begin(
            "PlaylistActionSubmenu.hoverOpen",
            detail: "surface=\(diagnosticSurface), \(detail)"
        )
        let _ = FirstUseHitchDiagnostics.end(hoverToken)
        let _ = FirstUseHitchDiagnostics.end(playlistToken)
        let _ = ContextMenuDiagnostics.end(submenuToken)

        ForEach(libraryVM.playlists) { playlist in
            if selectedPlaylistID != playlist.id {
                Button {
                    let token = ContextMenuDiagnostics.beginActionInvoke(
                        surface: diagnosticSurface,
                        detail: "action=addToPlaylist, track=\(trackIDPrefix), playlist=\(FirstUseHitchDiagnostics.trackIDPrefix(playlist.id))"
                    )
                    Task {
                        await libraryVM.addTracksToPlaylist([track], playlist: playlist)
                        ContextMenuDiagnostics.end(token)
                    }
                } label: {
                    Label(playlist.name, systemImage: "music.note.list")
                }
            }
        }

        Divider()

        Button {
            let token = ContextMenuDiagnostics.beginActionInvoke(
                surface: diagnosticSurface,
                detail: "action=createPlaylistAndAdd, track=\(trackIDPrefix)"
            )
            Task {
                guard let playlist = await libraryVM.createNewPlaylist() else {
                    ContextMenuDiagnostics.end(token)
                    return
                }
                await libraryVM.addTracksToPlaylist([track], playlist: playlist)
                ContextMenuDiagnostics.end(token)
            }
        } label: {
            Label("新建播放列表", systemImage: "plus")
        }
    }

    private var trackIDPrefix: String {
        FirstUseHitchDiagnostics.trackIDPrefix(track.id)
    }

    private var currentManualLikeState: ManualLikeState {
        let _ = libraryVM.refreshTrigger
        return libraryVM.preferenceStats(for: track.id).manualLikeState
    }

    private func invokeAction(_ actionName: String, _ action: () -> Void) {
        let token = ContextMenuDiagnostics.beginActionInvoke(
            surface: diagnosticSurface,
            detail: "action=\(actionName), track=\(trackIDPrefix)"
        )
        action()
        ContextMenuDiagnostics.end(token)
    }

    private var shouldShowArtistNavigation: Bool {
        guard case .artist = libraryVM.currentSelection else { return true }
        return false
    }

    private var shouldShowAlbumNavigation: Bool {
        guard case .album = libraryVM.currentSelection else { return true }
        return false
    }

    private var canRelocateAudioFile: Bool {
        guard track.availability != .available,
              case let .referenced(locator) = track.mediaLocator else {
            return false
        }
        return locator.sourceMemberships.isEmpty
    }
}

struct NowPlayingInfoContextMenu: View {
    let presentation: NowPlayingPresentation
    let onEditTrack: (Track) -> Void
    let onEditExternalInfo: () -> Void

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState

    var body: some View {
        if let track = presentation.localTrack {
            Button {
                onEditTrack(track)
            } label: {
                Label("编辑歌曲信息", systemImage: "info.circle")
            }

            if track.availability != .available,
               case let .referenced(locator) = track.mediaLocator,
               locator.sourceMemberships.isEmpty {
                Button {
                    TrackAudioRelocationAction(
                        libraryVM: libraryVM,
                        uiState: uiState
                    ).run(for: track)
                } label: {
                    Label("重新定位音频文件…", systemImage: "waveform.badge.magnifyingglass")
                }
            }
        }

        if presentation.source.isExternal,
           presentation.externalStableKey != nil {
            Button {
                onEditExternalInfo()
            } label: {
                Label("编辑外部播放覆盖信息", systemImage: "slider.horizontal.3")
            }
        }
    }
}

@MainActor
private struct TrackAudioRelocationAction {
    let libraryVM: LibraryViewModel
    let uiState: UIStateViewModel

    func run(for track: Track) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = AudioFormatSupport.playableOpenPanelContentTypes
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let access = LibraryInitialImportSelection(urls: [url])
        Task {
            defer { access.release() }
            do {
                let proposal = try await libraryVM.prepareTrackRelocation(
                    trackID: track.id,
                    selectedURL: url
                )
                let confirmed = !proposal.requiresReplacementConfirmation
                    || confirmReplacement(fileName: url.lastPathComponent)
                guard confirmed else { return }
                try await libraryVM.relocateTrack(
                    proposal,
                    confirmedReplacement: confirmed
                )
                uiState.showSidebarNotice("音频文件已连接")
            } catch SourceReconnectServiceError.unsupportedAudioFormat {
                uiState.showSidebarNotice("不支持所选音频格式", style: .warning)
            } catch {
                uiState.showSidebarNotice("音频文件没有连接", style: .warning)
            }
        }
    }

    private func confirmReplacement(fileName: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "替换音频文件？"
        alert.informativeText = "“\(fileName)”与原文件身份不同。继续后会保留歌曲信息，只更新音频位置。"
        alert.addButton(withTitle: "替换")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

struct MiniPlayerRefetchLyricsButton: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(LibraryViewModel.self) private var libraryVM
    var onAction: (() -> Void)? = nil

    var body: some View {
        if AppBuild.current < AppBuild(10) {
            // 这是为旧歌词转换质量问题提供的临时补救入口；过渡期结束后应删除该菜单项、门限判断及相关临时代码，而不是长期保留隐藏分支。
            Button {
                onAction?()
                playbackCoordinator.forceRefetchLyrics(libraryVM: libraryVM)
            } label: {
                Label("重新获取歌词", systemImage: "arrow.clockwise")
            }
        }
    }
}
