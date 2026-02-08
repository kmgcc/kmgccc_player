//
//  RotatingCoverSkin.swift
//  myPlayer2
//
//  TrueMusic - Rotating Cover Skin
//

import SwiftUI

struct RotatingCoverSkin: NowPlayingSkin {
    static let id: String = "rotatingCover"

    let id: String = RotatingCoverSkin.id
    let name: String = NSLocalizedString("skin.rotating_cover.name", comment: "")
    let detail: String = NSLocalizedString("skin.rotating_cover.detail", comment: "")
    let systemImage: String = "record.circle"

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(UnifiedNowPlayingBackground(context: context))
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        AnyView(RotatingCoverArtwork(context: context))
    }
}

private struct RotatingCoverArtwork: View {
    let context: SkinContext

    @State private var rotationBase: Double = 0
    @State private var rotationStart: Date? = nil
    @State private var lastTrackID: UUID? = nil

    var body: some View {
        let contentSize = context.contentSize
        let maxSize = min(contentSize.width * 0.55, contentSize.height * 0.55, 380)
        let discSize = max(200, maxSize)

        TimelineView(.animation) { timeline in
            let angle = context.theme.reduceMotion ? 0 : currentRotationAngle(at: timeline.date)

            artworkView
                .frame(width: discSize, height: discSize)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .rotationEffect(.degrees(angle))
                .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            lastTrackID = context.track?.id
            if context.playback.isPlaying {
                rotationStart = Date()
            }
        }
        .onChange(of: context.playback.isPlaying) { _, isPlaying in
            if isPlaying {
                rotationStart = Date()
            } else {
                rotationBase = currentRotationAngle(at: Date())
                rotationStart = nil
            }
        }
        .onChange(of: context.track?.id) { _, newID in
            if newID != lastTrackID {
                lastTrackID = newID
                rotationBase = 0
                rotationStart = context.playback.isPlaying ? Date() : nil
            }
        }
    }

    private func currentRotationAngle(at date: Date) -> Double {
        guard context.playback.isPlaying, let start = rotationStart else {
            return rotationBase
        }
        let elapsed = date.timeIntervalSince(start)
        let degreesPerSecond = 8.0
        return rotationBase + elapsed * degreesPerSecond
    }

    @ViewBuilder
    private var artworkView: some View {
        if let image = context.track?.artworkImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.indigo.opacity(0.45), Color.blue.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 52))
                        .foregroundStyle(.white.opacity(0.35))
                }
        }
    }
}
