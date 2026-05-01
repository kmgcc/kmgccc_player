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

    @Environment(LibraryViewModel.self) private var libraryVM

    var body: some View {
        if canSelectMultiple, let onSelectMultiple {
            Button {
                onSelectMultiple()
            } label: {
                Label("多选歌曲…", systemImage: "checkmark.circle")
            }

            Divider()
        }

        Button {
            onPlay()
        } label: {
            Label("播放", systemImage: "play")
        }

        Divider()

        Menu {
            ForEach(libraryVM.playlists) { playlist in
                if selectedPlaylistID != playlist.id {
                    Button {
                        Task {
                            await libraryVM.addTracksToPlaylist([track], playlist: playlist)
                        }
                    } label: {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                }
            }

            Divider()

            Button {
                Task {
                    let playlist = await libraryVM.createNewPlaylist()
                    await libraryVM.addTracksToPlaylist([track], playlist: playlist)
                }
            } label: {
                Label("新建播放列表", systemImage: "plus")
            }
        } label: {
            Label("添加到播放列表...", systemImage: "plus.circle")
        }
        .id("single_add_to_playlist_\(libraryVM.playlists.count)")

        if let onRemoveFromCurrentPlaylist {
            Button {
                onRemoveFromCurrentPlaylist(track)
            } label: {
                Label("从当前播放列表移除", systemImage: "minus.circle")
            }
        }

        Divider()

        Button {
            onEditTrack(track)
        } label: {
            Label("编辑歌曲信息", systemImage: "info.circle")
        }

        Divider()

        Button(role: .destructive) {
            Task {
                await libraryVM.deleteTrack(track)
            }
        } label: {
            Label("从资料库删除", systemImage: "trash")
        }
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
