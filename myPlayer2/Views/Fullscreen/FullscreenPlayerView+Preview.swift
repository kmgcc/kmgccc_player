//
//  FullscreenPlayerView+Preview.swift
//  myPlayer2
//

import SwiftUI

#Preview("Fullscreen Player") { @MainActor in
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)
    let lyricsVM = LyricsViewModel()
    let ledMeter = LEDMeterService()
    let skinManager = SkinManager()

    let track = Track(
        title: "Blinding Lights",
        artist: "The Weeknd",
        album: "After Hours",
        duration: 203,
        fileBookmarkData: Data()
    )

    FullscreenPlayerView(windowedArtBackgroundController: nil, onExitFullscreen: {})
        .environment(playerVM)
        .environment(lyricsVM)
        .environment(ledMeter)
        .environment(skinManager)
        .environmentObject(ThemeStore.shared)
        .frame(width: 1600, height: 1000)
        .onAppear {
            playerVM.playTracks([track])
        }
}
