//
//  NowPlayingInfoContextMenu.swift
//  myPlayer2
//
//  Shared context menu for mini player now-playing metadata actions.
//

import SwiftUI

struct TrackActionMenuContent: View {
    let track: Track
    var canSelectMultiple = false
    var selectedPlaylistID: UUID?
    var onSelectMultiple: (() -> Void)?
    let onPlay: () -> Void
    let onEditTrack: (Track) -> Void
    var onRemoveFromCurrentPlaylist: ((Track) -> Void)?
    var showsPlay: Bool = true
    var showsNavigation: Bool = true
    var diagnosticSurface: String = "TrackContextMenu"

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState

    init(
        track: Track,
        canSelectMultiple: Bool = false,
        selectedPlaylistID: UUID? = nil,
        onSelectMultiple: (() -> Void)? = nil,
        onPlay: @escaping () -> Void,
        onEditTrack: @escaping (Track) -> Void,
        onRemoveFromCurrentPlaylist: ((Track) -> Void)? = nil,
        showsPlay: Bool = true,
        showsNavigation: Bool = true,
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
        self.onEditTrack = onEditTrack
        self.onRemoveFromCurrentPlaylist = onRemoveFromCurrentPlaylist
        self.showsPlay = showsPlay
        self.showsNavigation = showsNavigation
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

            Divider()
        }

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

        Divider()

        Button(role: .destructive) {
            let token = ContextMenuDiagnostics.beginActionInvoke(
                surface: diagnosticSurface,
                detail: "action=deleteTrack, track=\(trackIDPrefix)"
            )
            Task {
                await libraryVM.deleteTrack(track)
                ContextMenuDiagnostics.end(token)
            }
        } label: {
            Label("从资料库删除", systemImage: "trash")
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
                let playlist = await libraryVM.createNewPlaylist()
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
}

struct NowPlayingInfoContextMenu: View {
    let presentation: NowPlayingPresentation
    let onEditTrack: (Track) -> Void
    let onEditExternalInfo: () -> Void

    var body: some View {
        if let track = presentation.localTrack {
            Button {
                onEditTrack(track)
            } label: {
                Label("编辑歌曲信息", systemImage: "info.circle")
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
