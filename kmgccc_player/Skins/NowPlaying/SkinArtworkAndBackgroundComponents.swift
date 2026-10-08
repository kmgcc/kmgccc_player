import AppKit
import SwiftUI

struct SkinArtworkComponent: View {
    let snapshot: SkinSceneSnapshot
    var configuration = SkinComponentConfiguration()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            Group {
                if configuration.boolean("artisticEdge", fallback: false) {
                    ClassicArtworkCoverContainer(
                        context: snapshot.context, size: size, displayScale: displayScale, rasterScale: 1,
                        frameMaskOverride: true,
                        cornerRadius: configuration.number("cornerRadius", fallback: 12)
                    )
                } else if let image = snapshot.track?.artworkImage {
                    let fills = configuration.text("fit", fallback: "fit") == "fill"
                    let ratio = image.size.width / max(1, image.size.height)
                    let width = min(proxy.size.width, proxy.size.height * ratio)
                    let height = width / max(0.01, ratio)
                    Image(nsImage: image).resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: fills ? proxy.size.width : width, height: fills ? proxy.size.height : height)
                        .clipShape(RoundedRectangle(cornerRadius: configuration.number("cornerRadius", fallback: 12)))
                } else {
                    ArtworkPlaceholderView.nowPlaying(size: size, cornerRadius: configuration.number("cornerRadius", fallback: 12))
                }
            }
            .blur(radius: configuration.number("blur", fallback: 0))
            .opacity(configuration.number("opacity", fallback: 1))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

struct SkinBackgroundComponent: View {
    let snapshot: SkinSceneSnapshot
    let configuration: SkinComponentConfiguration
    @Environment(\.skinSceneActions) private var actions

    var body: some View {
        GeometryReader { proxy in
            background(size: proxy.size)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .contentShape(Rectangle())
                .contextMenu {
                    Button("刷新皮肤", action: actions.reload)
                    Button("恢复外观", action: actions.restore)
                }
        }
    }

    @ViewBuilder
    private func background(size: CGSize) -> some View {
        switch configuration.text("mode", fallback: "solid") {
        case "preset":
            SkinRegistry.skin(for: configuration.text("preset", fallback: SkinRegistry.defaultFullscreenSkinID))
                .makeBackground(context: snapshot.context.withComponentBounds(size))
        case "artwork":
            if let image = snapshot.track?.artworkImage {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .blur(radius: configuration.number("blur", fallback: 36))
            }
        case "gradient":
            LinearGradient(
                colors: snapshot.theme.artworkPalette.map { Color(nsColor: $0) }.isEmpty
                    ? [snapshot.theme.accentColor, Color(nsColor: .windowBackgroundColor)]
                    : snapshot.theme.artworkPalette.map { Color(nsColor: $0) },
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        default:
            configuration.color(fallback: Color(nsColor: .windowBackgroundColor))
        }
    }
}

extension SkinContext {
    /// Reuse a built-in effect as a leaf without inheriting its former page layout.
    func withComponentBounds(_ size: CGSize) -> Self {
        .init(track: track, playback: playback, theme: theme, motionTokens: motionTokens, motionPolicy: motionPolicy,
              windowSize: size, contentBounds: CGRect(origin: .zero, size: size), fullscreenScale: 1,
              lyricsVisible: false, presentationMode: presentationMode, fullscreenHostMode: fullscreenHostMode)
    }
}
