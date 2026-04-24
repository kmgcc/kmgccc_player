//
//  NowPlayingInfoContextMenu.swift
//  myPlayer2
//
//  Shared context menu for mini player now-playing metadata actions.
//

import SwiftUI

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
