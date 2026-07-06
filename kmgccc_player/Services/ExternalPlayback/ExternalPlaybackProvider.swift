//
//  ExternalPlaybackProvider.swift
//  myPlayer2
//
//  Lightweight command/presentation surface for non-local playback sources.
//

import Foundation

struct ExternalPlaybackCapabilities: Equatable, Sendable {
    var canControlPlayback: Bool
    var canSkip: Bool
    var canSeek: Bool
    var canSetVolume: Bool
    var canSetPlaybackMode: Bool

    static let unavailable = ExternalPlaybackCapabilities(
        canControlPlayback: false,
        canSkip: false,
        canSeek: false,
        canSetVolume: false,
        canSetPlaybackMode: false
    )

    static let appleMusic = ExternalPlaybackCapabilities(
        canControlPlayback: true,
        canSkip: true,
        canSeek: true,
        canSetVolume: true,
        canSetPlaybackMode: true
    )
}

@MainActor
protocol ExternalPlaybackProvider: AnyObject {
    var source: PlaybackSource { get }
    var presentation: NowPlayingPresentation { get }
    var capabilities: ExternalPlaybackCapabilities { get }

    func start()
    func stop()
    func tickPresentation()
    func playPause()
    func play()
    func pause()
    func next()
    func previous()
    func seek(to seconds: Double)
    func setVolume(_ volume: Double)
    func setPlaybackOrderMode(_ mode: PlaybackOrderMode)
    func setAppleMusicPlaybackMode(_ mode: AppleMusicPlaybackMode)
    func invalidateCurrentResolution()
    func clearRuntimeResolutionCaches()
}

extension ExternalPlaybackProvider {
    var capabilities: ExternalPlaybackCapabilities { .unavailable }
    func tickPresentation() {}
    func setVolume(_ volume: Double) {}
}

extension AppleMusicPlaybackAdapter: ExternalPlaybackProvider {
    var source: PlaybackSource { .appleMusic }
    var capabilities: ExternalPlaybackCapabilities { .appleMusic }
}
