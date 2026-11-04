import SwiftUI

/// Isolates high-frequency playback observation from the fullscreen scene root.
/// The callbacks drive fullscreen auto-hide without rebuilding the artwork,
/// skin and control hierarchy for every clock tick.
///
/// Both sources are the coordinator's 4 Hz progress channel. Reading
/// `playerVM.currentTime` instead subscribed to the audio service's own 10 Hz
/// clock, and each of those ticks still pulled downstream bodies through the
/// view graph; auto-hide timing does not need that resolution.
@MainActor
struct FullscreenPlaybackSyncView: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator

    let onLocalTimeChange: (Double, Double) -> Void
    let onExternalTimeChange: (Double, Double) -> Void

    var body: some View {
        Color.clear
            .onChange(of: playbackCoordinator.playbackProgress.currentTime) { oldTime, newTime in
                onLocalTimeChange(oldTime, newTime)
                onExternalTimeChange(oldTime, newTime)
            }
    }
}
