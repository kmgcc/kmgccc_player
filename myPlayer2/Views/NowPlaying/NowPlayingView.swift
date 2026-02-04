//
//  NowPlayingView.swift
//  myPlayer2
//
//  TrueMusic - Now Playing View
//  Minimal playback view with large artwork and LED meter.
//  No title text, no controls (controls are in MiniPlayer).
//

import SwiftUI

/// Minimal now playing view.
/// Displays only: large album art + LED meter + blurred background.
/// Title/controls are in the MiniPlayer bar.
struct NowPlayingView: View {

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(UIStateViewModel.self) private var uiState

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background: blurred artwork
                backgroundView

                // Content
                VStack(spacing: 0) {
                    // Back button row
                    backButtonRow

                    Spacer()

                    // Album artwork (centered)
                    artworkView
                        .frame(
                            width: min(geometry.size.width * 0.45, 320),
                            height: min(geometry.size.width * 0.45, 320)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)

                    Spacer()
                        .frame(height: 40)

                    // LED Meter (larger, more visible)
                    LedMeterView(level: Double(playerVM.level), dotSize: 12, spacing: 10)
                        .padding(.horizontal, 40)

                    Spacer()
                }
                .padding(32)
            }
        }
    }

    // MARK: - Subviews

    private var backgroundView: some View {
        ZStack {
            // Base dark gradient
            Color.black.opacity(0.85)

            // Artwork blur (if available)
            if let artworkData = playerVM.currentTrack?.artworkData,
                let nsImage = NSImage(data: artworkData)
            {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 100)
                    .opacity(0.4)
            } else {
                // Fallback gradient
                LinearGradient(
                    colors: [
                        Color.purple.opacity(0.2),
                        Color.blue.opacity(0.15),
                        Color.black.opacity(0.9),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }

    private var backButtonRow: some View {
        HStack {
            Button {
                uiState.showLibrary()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Library")
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artworkData = playerVM.currentTrack?.artworkData,
            let nsImage = NSImage(data: artworkData)
        {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [.purple.opacity(0.5), .blue.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 60))
                        .foregroundStyle(.white.opacity(0.4))
                }
        }
    }
}

// MARK: - Preview

#Preview("Now Playing") {
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)
    let uiState = UIStateViewModel()

    let track = Track(
        title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", duration: 203,
        fileBookmarkData: Data())

    NowPlayingView()
        .environment(playerVM)
        .environment(uiState)
        .frame(width: 600, height: 500)
        .preferredColorScheme(.dark)
        .onAppear {
            playerVM.playTracks([track])
        }
}
