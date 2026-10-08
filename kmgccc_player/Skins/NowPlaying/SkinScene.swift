import SwiftUI

/// A native author chooses the view hierarchy and responds to the actual viewport.
/// This App-internal rendering interface is independent of the JSON package vocabulary.
struct SkinScene {
    private let render: (SkinSceneSnapshot, SkinViewport, SkinComponents) -> AnyView

    init<Content: View>(
        @ViewBuilder content: @escaping (SkinSceneSnapshot, SkinViewport, SkinComponents) -> Content
    ) {
        render = { snapshot, viewport, components in
            AnyView(content(snapshot, viewport, components))
        }
    }

    func makeContent(
        snapshot: SkinSceneSnapshot,
        viewport: SkinViewport,
        components: SkinComponents
    ) -> AnyView {
        render(snapshot, viewport, components)
    }
}

/// Stable content only. Progress, lyrics time and analysis remain in their leaf components.
struct SkinSceneSnapshot {
    let context: SkinContext
    let track: SkinContext.TrackMetadata?
    let playback: SkinContext.PlaybackState
    let theme: SkinContext.ThemeTokens

    init(context: SkinContext) {
        self.context = context
        track = context.track
        playback = context.playback
        theme = context.theme
    }
}

struct SkinViewport {
    let size: CGSize
    let surface: SkinSurface
    let fullscreenHost: SkinContext.FullscreenHostMode
}
