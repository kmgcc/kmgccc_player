import SwiftUI

/// Isolates high-frequency playback observation from the fullscreen scene root.
/// The callbacks update the lyric surface directly; the surrounding artwork,
/// skin and control hierarchy does not need to be rebuilt for every clock tick.
@MainActor
struct FullscreenPlaybackSyncView: View {
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator

    let onLocalTimeChange: (Double, Double) -> Void
    let onLocalPlayingChange: (Bool) -> Void
    let onExternalTimeChange: (Double, Double) -> Void
    let onExternalPlayingChange: (Bool) -> Void

    var body: some View {
        Color.clear
            .onChange(of: playerVM.currentTime) { oldTime, newTime in
                onLocalTimeChange(oldTime, newTime)
            }
            .onChange(of: playerVM.isPlaying) { _, newValue in
                onLocalPlayingChange(newValue)
            }
            .onChange(of: playbackCoordinator.presentation.currentTime) { oldTime, newTime in
                onExternalTimeChange(oldTime, newTime)
            }
            .onChange(of: playbackCoordinator.presentation.effectiveLyricsIsPlaying) { _, newValue in
                onExternalPlayingChange(newValue)
            }
    }
}
