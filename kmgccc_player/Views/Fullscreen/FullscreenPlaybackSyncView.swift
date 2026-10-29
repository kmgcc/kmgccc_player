import SwiftUI

/// Isolates high-frequency playback observation from the fullscreen scene root.
/// The callbacks drive fullscreen auto-hide without rebuilding the artwork,
/// skin and control hierarchy for every clock tick.
@MainActor
struct FullscreenPlaybackSyncView: View {
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator

    let onLocalTimeChange: (Double, Double) -> Void
    let onExternalTimeChange: (Double, Double) -> Void

    var body: some View {
        Color.clear
            .onChange(of: playerVM.currentTime) { oldTime, newTime in
                onLocalTimeChange(oldTime, newTime)
            }
            .onChange(of: playbackCoordinator.presentation.currentTime) { oldTime, newTime in
                onExternalTimeChange(oldTime, newTime)
            }
    }
}
