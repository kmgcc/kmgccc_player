//
//  NowPlayingView.swift
//  myPlayer2
//
//  kmgccc_player - Now Playing View
//  Wrapper for the skinned host view.
//

import SwiftUI

struct NowPlayingView: View {
    var body: some View {
        NowPlayingHostView()
    }
}

#Preview("Now Playing") {
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)
    let ledMeter = LEDMeterService()
    let skinManager = SkinManager()
    let uiState = UIStateViewModel()

    let track = Track(
        title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", duration: 203,
        fileBookmarkData: Data())

    NowPlayingView()
        .environment(playerVM)
        .environment(uiState)
        .environment(ledMeter)
        .environment(skinManager)
        .frame(width: 600, height: 500)
        .preferredColorScheme(.dark)
        .onAppear {
            playerVM.playTracks([track])
        }
}
