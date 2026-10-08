import MotionKit
import SwiftUI

@MainActor
struct FullscreenSkinArtworkArea: View {
    let skin: any NowPlayingSkin
    let context: SkinContext
    let artworkScale: CGFloat
    let groupLeftShift: CGFloat
    let onShowDetails: () -> Void
    let onRefreshLyricsColors: () -> Void

    var body: some View {
        ZStack {
            skin.makeArtwork(context: context)
                .scaleEffect(artworkScale)

            if let overlay = skin.makeOverlay(context: context) {
                overlay
                    .scaleEffect(artworkScale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .offset(x: -groupLeftShift)
        .contentShape(Rectangle())
        .contextMenu {
            FullscreenSkinContextMenu(
                onShowDetails: onShowDetails,
                onRefreshLyricsColors: onRefreshLyricsColors
            )
        }
    }
}

struct FullscreenSkinContextMenu: View {
    let onShowDetails: () -> Void
    let onRefreshLyricsColors: () -> Void

    var body: some View {
        Group {
            Button(action: onShowDetails) {
                Label("查看详情", systemImage: "doc.text")
            }

            Button(action: onRefreshLyricsColors) {
                Label(
                    NSLocalizedString(
                        "fullscreen.refresh_lyrics_colors",
                        comment: "Refresh fullscreen lyrics color sampling"
                    ),
                    systemImage: "arrow.clockwise"
                )
            }
        }
    }
}

@MainActor
struct FullscreenScaledArtworkContainer<Content: View>: View {
    let movesArtworkWithControls: Bool
    let areControlsVisible: Bool
    let horizontalPadding: CGFloat
    let controlsBottomPadding: CGFloat
    let controlButtonSize: CGFloat
    let content: Content

    init(
        movesArtworkWithControls: Bool,
        areControlsVisible: Bool,
        horizontalPadding: CGFloat,
        controlsBottomPadding: CGFloat,
        controlButtonSize: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.movesArtworkWithControls = movesArtworkWithControls
        self.areControlsVisible = areControlsVisible
        self.horizontalPadding = horizontalPadding
        self.controlsBottomPadding = controlsBottomPadding
        self.controlButtonSize = controlButtonSize
        self.content = content()
    }

    var body: some View {
        let coverDropY: CGFloat = movesArtworkWithControls && !areControlsVisible ? 20 : 0

        ZStack {
            VStack(spacing: 0) {
                content
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                    .offset(y: coverDropY)
                    .motionAnimation(.navigation, value: areControlsVisible)

                Spacer(minLength: controlsBottomPadding + controlButtonSize)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
