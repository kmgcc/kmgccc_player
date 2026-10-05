import SwiftUI

/// Shared transport presentation. Each surface supplies its own geometry and colors.
struct PlaybackTransportControls: View {
    let isPlaying: Bool
    let isEnabled: Bool
    let hasTrack: Bool
    let metrics: AnimatedMediaControlMetrics
    let color: Color
    let disabledColor: Color
    var blendMode: BlendMode = .normal
    var spacing: CGFloat = 14
    let previous: () -> Void
    let playPause: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: spacing) {
            AnimatedSkipButton(
                direction: .previous,
                enabled: isEnabled && hasTrack,
                metrics: metrics,
                color: color,
                disabledColor: disabledColor,
                blendMode: blendMode,
                action: previous
            )
            AnimatedPlayPauseButton(
                isPlaying: isPlaying,
                enabled: isEnabled,
                metrics: metrics,
                color: color,
                disabledColor: disabledColor,
                blendMode: blendMode,
                action: playPause
            )
            AnimatedSkipButton(
                direction: .next,
                enabled: isEnabled && hasTrack,
                metrics: metrics,
                color: color,
                disabledColor: disabledColor,
                blendMode: blendMode,
                action: next
            )
        }
    }
}
