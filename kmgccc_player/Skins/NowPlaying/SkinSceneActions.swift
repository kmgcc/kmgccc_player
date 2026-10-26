import SwiftUI

/// Narrow command adapter. The existing domain services still execute every operation.
struct SkinSceneActions {
    var playPause: () -> Void = {}
    var previous: () -> Void = {}
    var next: () -> Void = {}
    var seek: (Double) -> Void = { _ in }
    var setVolume: @MainActor @Sendable (Double) -> Void = { _ in }
    var setPlaybackOrder: (PlaybackOrderMode) -> Void = { _ in }
    var setExternalPlaybackOrder: (AppleMusicPlaybackMode) -> Void = { _ in }
    var like: () -> Void = {}
    var toggleQueue: () -> Void = {}
    var toggleLyrics: () -> Void = {}
    var enterFullscreen: () -> Void = {}
    var exit: () -> Void = {}
    var openSettings: () -> Void = {}
    var openQuickPanel: () -> Void = {}
    var reload: () -> Void = {}
    var restore: () -> Void = {}
    var stop: () -> Void = {}
    var playQueueIndex: (Int) -> Void = { _ in }
    var openTrackDetail: () -> Void = {}
    var openTrackEdit: () -> Void = {}
    var openExternalInfo: () -> Void = {}
    var setParameter: (String, SkinParameterValue) -> Void = { _, _ in }
    var play: () -> Void = {}
    var pause: () -> Void = {}
    var seekAndResume: (Double) -> Void = { _ in }
    var setLikeState: (ManualLikeState) -> Void = { _ in }
    var toggleDislike: () -> Void = {}
    /// A playlist ID, or nil for a new playlist that receives the current track.
    var addToPlaylist: (UUID?) -> Void = { _ in }
    /// Asks for confirmation before the current track leaves the library.
    var deleteTrack: () -> Void = {}
    var openMusicInfo: () -> Void = {}
    var showArtist: () -> Void = {}
    var showAlbum: () -> Void = {}
    /// A device UID, or nil to follow the system output.
    var selectOutput: (String?) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var skinSceneActions = SkinSceneActions()
    @Entry var skinSceneSurface = SkinSurface.window
    @Entry var skinSceneFullscreenHost = SkinContext.FullscreenHostMode.none
    @Entry var skinSceneLyricsRenderingEnabled = false
    @Entry var skinSceneLyricsVisible = true
    @Entry var skinSceneSession: SkinSession?
    @Entry var skinSceneIsActive = true
    @Entry var skinPackageResources: URL?
    @Entry var skinPackageFonts: [String] = []
}

struct SkinTransportComponent: View {
    let configuration: SkinComponentConfiguration
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(\.skinSceneActions) private var actions

    var body: some View {
        let presentation = playbackCoordinator.stablePresentation
        PlaybackTransportControls(
            isPlaying: presentation.isPlaying, isEnabled: presentation.isControlEnabled,
            hasTrack: presentation.hasTrack, metrics: configuration.mediaControlMetrics(navigation: false),
            color: configuration.color(fallback: .primary), disabledColor: configuration.color("disabledColor", fallback: .secondary),
            blendMode: SkinNodeStyle.blendMode(configuration.text("blendMode", fallback: "normal")),
            spacing: configuration.number("spacing", fallback: 14),
            previous: actions.previous, playPause: actions.playPause, next: actions.next
        )
    }
}

struct SkinProgressComponent: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(\.skinSceneActions) private var actions
    @State private var isDragging = false
    @State private var value: Double = 0

    var body: some View {
        let presentation = playbackCoordinator.presentation
        Slider(value: Binding(
            get: { isDragging ? value : presentation.currentTime },
            set: { value = $0 }
        ), in: 0...max(1, presentation.duration)) { editing in
            if editing { value = presentation.currentTime }
            else { actions.seek(value) }
            isDragging = editing
        }
        .disabled(!presentation.isSeekEnabled)
    }
}
