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
    @Environment(UIStateViewModel.self) private var uiState

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

        if shouldShowArtistNavigation {
            Button {
                libraryVM.navigateToArtist(for: track, uiState: uiState)
            } label: {
                Label("查看艺人", systemImage: "person.crop.circle")
            }
        }

        if shouldShowAlbumNavigation {
            Button {
                libraryVM.navigateToAlbum(for: track, uiState: uiState)
            } label: {
                Label("查看专辑", systemImage: "rectangle.stack")
            }
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
