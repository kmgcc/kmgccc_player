#if DEBUG
import SwiftUI

/// Opt-in authoring example. Start the Debug app with --skin-development-example.
struct MinimalSkinExample: NowPlayingSkin {
    let descriptor = SkinDescriptor(
        id: "development.minimal",
        name: "Skin Example",
        detail: "Minimal native skin",
        systemImage: "photo",
        audio: SkinAudioDefaults(supportsEmbeddedVisualizer: false, hasLedMeter: false)
    )

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(UnifiedNowPlayingBackground(context: context))
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        AnyView(
            Group {
                if let image = context.track?.artworkImage {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "music.note").font(.largeTitle)
                }
            }
            .foregroundStyle(context.theme.accentColor)
            .frame(
                width: min(context.contentSize.width * 0.7, 420),
                height: min(context.contentSize.height * 0.7, 420)
            )
        )
    }
}
#endif
