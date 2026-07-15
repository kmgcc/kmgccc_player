//
//  LyricsPlaybackPipeline.swift
//  myPlayer2
//
//  Stable playback-to-lyrics state pipeline.
//

import Foundation

@MainActor
final class LyricsPlaybackPipeline {
    private struct ContentState: Equatable {
        let source: PlaybackSource
        let trackID: UUID?
        let lyricsIdentity: String?
        let presentationLyricsText: String?
        let trackTTMLText: String?
        let trackLyricsText: String?
        let ttmlFileName: String?
        let lyricsFileName: String?
        let externalStableKey: String?
        let externalStatusMessage: String?
    }

    private weak var lyricsVM: LyricsViewModel?
    private weak var playbackCoordinator: PlaybackCoordinator?

    private var lastContentState: ContentState?
    private var lastHadTrack = false
    private var lastIsPlaying: Bool?
    private var lastSyncedTime: Double?

    init(
        lyricsVM: LyricsViewModel,
        playbackCoordinator: PlaybackCoordinator
    ) {
        self.lyricsVM = lyricsVM
        self.playbackCoordinator = playbackCoordinator
    }

    func start() {
        playbackCoordinator?.onPresentationChanged = { [weak self] oldPresentation, newPresentation in
            self?.handlePresentationChanged(
                from: oldPresentation,
                to: newPresentation,
                reason: "presentation changed"
            )
        }
        refreshCurrent(reason: "pipeline start", forceLyricsReload: true)
    }

    func refreshCurrent(reason: String, forceLyricsReload: Bool = false) {
        guard let presentation = playbackCoordinator?.presentation else { return }
        applyPresentation(
            presentation,
            reason: reason,
            forceLyricsReload: forceLyricsReload
        )
    }

    private func handlePresentationChanged(
        from oldPresentation: NowPlayingPresentation,
        to newPresentation: NowPlayingPresentation,
        reason: String
    ) {
        let oldContentState = contentState(for: oldPresentation)
        let newContentState = contentState(for: newPresentation)
        let contentChanged = lastContentState != newContentState || oldContentState != newContentState
        let trackAppeared = !lastHadTrack && newPresentation.hasTrack

        if contentChanged || trackAppeared {
            applyPresentation(
                newPresentation,
                reason: reason,
                forceLyricsReload: true
            )
            return
        }

        syncPlaybackState(newPresentation)
        remember(presentation: newPresentation, contentState: newContentState)
    }

    private func applyPresentation(
        _ presentation: NowPlayingPresentation,
        reason: String,
        forceLyricsReload: Bool
    ) {
        guard let lyricsVM else { return }
        let contentState = contentState(for: presentation)

        switch presentation.source {
        case .local:
            lyricsVM.ensureAMLLLoaded(
                track: presentation.localTrack,
                currentTime: presentation.lyricsCurrentTime,
                isPlaying: presentation.isPlaying,
                reason: "pipeline \(reason)",
                forceLyricsReload: forceLyricsReload
            )
        case .appleMusic, .systemNowPlaying:
            lyricsVM.ensureExternalAMLLLoaded(
                presentation: presentation,
                reason: "pipeline \(reason)",
                forceLyricsReload: forceLyricsReload
            )
        }

        remember(presentation: presentation, contentState: contentState)
    }

    private func syncPlaybackState(_ presentation: NowPlayingPresentation) {
        guard let lyricsVM else { return }

        // An offset-only change (e.g. user edited the external override) does not
        // alter the lyrics content signature, so it would otherwise be treated as
        // a plain sync and never re-push the AMLL config. Reconcile the external
        // offset here so offset edits refresh the lyrics config immediately.
        if presentation.source.isExternal {
            lyricsVM.applyExternalLyricsOffset(presentation.externalLyricsTimeOffsetMs ?? 0)
        }

        let currentTime = presentation.lyricsCurrentTime
        if lastSyncedTime == nil || abs((lastSyncedTime ?? 0) - currentTime) >= 0.01 {
            lyricsVM.syncTime(currentTime)
        }

        let isPlaying = presentation.effectiveLyricsIsPlaying
        if lastIsPlaying != isPlaying {
            lyricsVM.setPlaying(isPlaying)
        }
    }

    private func remember(
        presentation: NowPlayingPresentation,
        contentState: ContentState
    ) {
        lastContentState = contentState
        lastHadTrack = presentation.hasTrack
        lastIsPlaying = presentation.effectiveLyricsIsPlaying
        lastSyncedTime = presentation.lyricsCurrentTime
    }

    private func contentState(for presentation: NowPlayingPresentation) -> ContentState {
        switch presentation.source {
        case .local:
            let track = presentation.localTrack
            return ContentState(
                source: presentation.source,
                trackID: track?.id,
                lyricsIdentity: presentation.lyricsIdentity,
                presentationLyricsText: presentation.lyricsText,
                trackTTMLText: track?.ttmlLyricText,
                trackLyricsText: track?.lyricsText,
                ttmlFileName: track?.ttmlLyricsFileName,
                lyricsFileName: track?.lyricsFileName,
                externalStableKey: nil,
                externalStatusMessage: nil
            )
        case .appleMusic, .systemNowPlaying:
            return ContentState(
                source: presentation.source,
                trackID: nil,
                lyricsIdentity: presentation.lyricsIdentity,
                presentationLyricsText: presentation.lyricsText,
                trackTTMLText: nil,
                trackLyricsText: nil,
                ttmlFileName: nil,
                lyricsFileName: nil,
                externalStableKey: presentation.externalStableKey,
                externalStatusMessage: presentation.externalLyricsStatusMessage
            )
        }
    }
}
