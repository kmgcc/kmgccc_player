//
//  LyricsPanelView.swift
//  myPlayer2
//
//  TrueMusic - Lyrics Panel View
//  Right-side panel hosting AMLL lyrics with player state binding.
//

import SwiftUI

/// Right-side lyrics panel with AMLL WebView.
/// Syncs with player state and handles user interactions.
struct LyricsPanelView: View {

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(LyricsViewModel.self) private var lyricsVM

    // Watch settings to trigger AMLL updates (live)
    @AppStorage("appearance") private var appearance: String = "system"
    @AppStorage("lyricsFontSize") private var lyricsFontSize: Double = 24.0
    @AppStorage("lyricsFontNameZh") private var lyricsFontNameZh: String = "PingFang SC"
    @AppStorage("lyricsFontNameEn") private var lyricsFontNameEn: String = "SF Pro Text"
    @AppStorage("lyricsTranslationFontName") private var lyricsTranslationFontName: String = "SF Pro Text"
    @AppStorage("lyricsFontWeight") private var lyricsFontWeight: Int = 600
    @AppStorage("lyricsLeadInMs") private var lyricsLeadInMs: Double = 300

    var body: some View {
        VStack(spacing: 0) {
            // Lyrics WebView
            AMLLWebView(bridge: lyricsVM.bridge, resourceBundle: .main)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                // Keep lyrics content below the titlebar while allowing the glass
                // surface to extend to the very top.
                .safeAreaPadding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassRect(cornerRadius: 0)
        // Sync Player State
        .onChange(of: playerVM.currentTime) { _, newTime in
            lyricsVM.syncTime(newTime)
        }
        .onChange(of: playerVM.isPlaying) { _, isPlaying in
            lyricsVM.setPlaying(isPlaying)
        }
        .onChange(of: playerVM.currentTrack?.id) { oldId, newId in
            if oldId != newId {
                lyricsVM.applyTrack(playerVM.currentTrack)
            }
        }
        // Config Updates
        .onChange(of: lyricsFontSize) { _, _ in
            lyricsVM.refreshConfigFromSettings()
        }
        .onChange(of: lyricsFontNameZh) { _, _ in
            lyricsVM.refreshConfigFromSettings()
        }
        .onChange(of: lyricsFontNameEn) { _, _ in
            lyricsVM.refreshConfigFromSettings()
        }
        .onChange(of: lyricsTranslationFontName) { _, _ in
            lyricsVM.refreshConfigFromSettings()
        }
        .onChange(of: lyricsFontWeight) { _, _ in
            lyricsVM.refreshConfigFromSettings()
        }
        .onChange(of: lyricsLeadInMs) { _, _ in
            lyricsVM.refreshConfigFromSettings()
        }
        .onChange(of: appearance) { _, _ in
            lyricsVM.refreshConfigFromSettings()
        }
        .onAppear {
            setupSeekCallback()
            lyricsVM.applyTrack(playerVM.currentTrack)
            lyricsVM.refreshConfigFromSettings()
        }
    }

    // MARK: - Actions

    private func setupSeekCallback() {
        lyricsVM.onSeekRequest = { seconds in
            playerVM.seek(to: seconds)
        }
    }

}

// MARK: - Preview

#Preview("Lyrics Panel") {
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)
    let lyricsVM = LyricsViewModel()

    HStack(spacing: 0) {
        Color.gray.opacity(0.3)
            .frame(width: 400)

        LyricsPanelView()
            .environment(playerVM)
            .environment(lyricsVM)
    }
    .frame(width: 800, height: 600)
    .preferredColorScheme(.dark)
}
