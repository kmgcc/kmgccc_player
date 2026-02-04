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
    @AppStorage("nowPlayingSkin") private var nowPlayingSkin: String = NowPlayingSkin.coverLed.rawValue

    @State private var rotationBase: Double = 0
    @State private var rotationStart: Date? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background: blurred artwork
                backgroundView

                // Content
                VStack(spacing: 0) {
                    // Back button row
                    headerRow

                    Spacer()

                    skinContent(in: geometry)

                    Spacer()
                }
                .padding(32)
            }
            .onChange(of: playerVM.isPlaying) { _, isPlaying in
                if isPlaying {
                    rotationStart = Date()
                } else {
                    rotationBase = currentRotationAngle(at: Date())
                    rotationStart = nil
                }
            }
            .onChange(of: nowPlayingSkin) { _, newValue in
                if newValue == NowPlayingSkin.rotatingCover.rawValue, playerVM.isPlaying {
                    rotationStart = Date()
                }
            }
            .onAppear {
                if playerVM.isPlaying {
                    rotationStart = Date()
                }
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

    private var headerRow: some View {
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
    private func skinContent(in geometry: GeometryProxy) -> some View {
        let selected = NowPlayingSkin(rawValue: nowPlayingSkin) ?? .coverLed
        switch selected {
        case .coverLed:
            VStack(spacing: 0) {
                artworkView
                    .frame(
                        width: min(geometry.size.width * 0.45, 320),
                        height: min(geometry.size.width * 0.45, 320)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)

                Spacer()
                    .frame(height: 40)

                LedMeterView(level: Double(playerVM.level), dotSize: 12, spacing: 10)
                    .padding(.horizontal, 40)
            }
        case .rotatingCover:
            TimelineView(.animation) { timeline in
                let angle = currentRotationAngle(at: timeline.date)
                rotatingArtwork(angle: angle, size: min(geometry.size.width * 0.5, 360))
            }
        }
    }

    private func rotatingArtwork(angle: Double, size: CGFloat) -> some View {
        artworkView
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .rotationEffect(.degrees(angle))
            .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
    }

    private func currentRotationAngle(at date: Date) -> Double {
        guard playerVM.isPlaying, let start = rotationStart else {
            return rotationBase
        }
        let elapsed = date.timeIntervalSince(start)
        let degreesPerSecond = 8.0
        return rotationBase + elapsed * degreesPerSecond
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
