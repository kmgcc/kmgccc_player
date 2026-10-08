import SwiftUI

/// Fade ranges are fractions of the component's live height, independent of window size.
struct SkinLyricsEdgeFade: ViewModifier {
    let configuration: SkinComponentConfiguration
    func body(content: Content) -> some View {
        let top = min(0.5, max(0, configuration.number("topFadeRange", fallback: 0)))
        let bottom = min(0.5, max(0, configuration.number("bottomFadeRange", fallback: 0)))
        content
            .frame(maxWidth: configuration.values["maximumWidth"].map { _ in CGFloat(configuration.number("maximumWidth", fallback: 1000)) })
            .mask {
                LinearGradient(stops: [
                    .init(color: .white.opacity(configuration.number("topEdgeOpacity", fallback: 1)), location: 0),
                    .init(color: .white, location: top),
                    .init(color: .white, location: 1 - bottom),
                    .init(color: .white.opacity(configuration.number("bottomEdgeOpacity", fallback: 1)), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
    }
}
