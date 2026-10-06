import MelismaKit
import SwiftUI

/// Read the same playback state used by the App, inside a custom control leaf.
struct SkinPlaybackReader<Content: View>: View {
    @Environment(PlaybackCoordinator.self) private var playback
    let content: (NowPlayingPresentation) -> Content
    init(@ViewBuilder content: @escaping (NowPlayingPresentation) -> Content) { self.content = content }
    var body: some View { content(playback.presentation) }
}

struct SkinLyricsData {
    let revision: UInt64
    let document: LyricsDocument?
    /// Processed line/word ranges include the App's timing adjustments.
    let timedGroups: [LyricGroup]?
    let currentTime: Double
    let isPlaying: Bool
    let configuration: LyricsConfiguration
    let originalTTML: String
    var rawDocumentTime: Double { currentTime - configuration.timing.trackOffset + configuration.timing.globalAdvance }
}

/// Read the lyric owner's shared document, even without a native lyrics component.
/// This reader never mounts a second lyric view or starts its display loop.
struct SkinLyricsReader<Content: View>: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.skinSceneSurface) private var surface
    let content: (SkinLyricsData) -> Content
    init(@ViewBuilder content: @escaping (SkinLyricsData) -> Content) { self.content = content }
    var body: some View {
        let manager = NativeLyricsSurfaceManager.shared
        let role: LyricsSurfaceRole = surface == .window ? .main : .fullscreen
        content(.init(
            revision: manager.documentPublication.revision,
            document: manager.documentForConsumers(), timedGroups: manager.timedGroupsForConsumers(role: role),
            currentTime: playback.presentation.lyricsCurrentTime,
            isPlaying: playback.presentation.effectiveLyricsIsPlaying,
            configuration: manager.configurationForConsumers(role: role), originalTTML: manager.currentTTML
        ))
    }
}

/// The envelope/FFT feed is owned by this leaf, not by SkinSceneSnapshot. Local
/// audio uses the existing Hub/provider; external apps do not expose real PCM.
struct SkinAudioReader<Content: View>: View {
    @Environment(LEDMeterServiceProvider.self) private var provider
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.skinSceneIsActive) private var isActive
    @Environment(\.skinSceneSession) private var session
    @State private var cleanupID: UUID?
    @State private var feed = SkinAudioFeed()
    let content: (SkinAudioData) -> Content
    init(@ViewBuilder content: @escaping (SkinAudioData) -> Content) { self.content = content }
    var body: some View {
        content(.init(frame: feed.frame, availability: feed.availability))
            .onAppear {
                cleanupID = session?.registerCleanup { feed.stop() }
                synchronize()
            }
            .onChange(of: isActive) { _, _ in synchronize() }
            .onChange(of: playback.stablePresentation.source) { _, _ in synchronize() }
            .onChange(of: playback.stablePresentation.isPlaying) { _, _ in synchronize() }
            .onDisappear {
                feed.stop()
                if let cleanupID { session?.removeCleanup(cleanupID) }
                cleanupID = nil
            }
    }
    private func synchronize() {
        feed.update(
            provider: provider,
            source: playback.stablePresentation.source,
            active: isActive,
            isPlaying: playback.stablePresentation.isPlaying
        )
    }
}
