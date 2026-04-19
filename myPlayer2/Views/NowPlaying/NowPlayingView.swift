//
//  NowPlayingView.swift
//  myPlayer2
//
//  kmgccc_player - Now Playing View
//  Wrapper for the skinned host view.
//

import SwiftUI

@MainActor
struct NowPlayingView: View {
    let mainContentWidth: CGFloat?

    init(mainContentWidth: CGFloat? = nil) {
        self.mainContentWidth = mainContentWidth
    }

    var body: some View {
        if let width = mainContentWidth {
            NowPlayingHostView(mainContentWidth: width)
        } else {
            GeometryReader { proxy in
                NowPlayingHostView(mainContentWidth: proxy.size.width)
            }
        }
    }
}

#Preview("Now Playing") { @MainActor in
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)
    let playbackCoordinator = PlaybackCoordinator(playerVM: playerVM)
    let ledMeter = LEDMeterService()
    let skinManager = SkinManager()
    let uiState = UIStateViewModel()

    let track = Track(
        title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", duration: 203,
        fileBookmarkData: Data())

    NowPlayingView()
        .environment(playerVM)
        .environment(playbackCoordinator)
        .environment(uiState)
        .environment(ledMeter)
        .environment(skinManager)
        .frame(width: 600, height: 500)
        .preferredColorScheme(.dark)
        .onAppear {
            playerVM.playTracks([track])
        }
}
