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
    private var lastTransportIsPlaying: Bool?
    private var lastSyncedTime: Double?
    private var lastSeekRevision: Int?

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
        lastSeekRevision = playbackCoordinator?.lyricsSeekRevision
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
            lyricsVM.ensureLyricsLoaded(
                track: presentation.localTrack,
                currentTime: presentation.lyricsCurrentTime,
                isPlaying: presentation.effectiveLyricsIsPlaying,
                reason: "pipeline \(reason)",
                forceLyricsReload: forceLyricsReload
            )
        case .appleMusic, .systemNowPlaying:
            lyricsVM.ensureExternalLyricsLoaded(
                presentation: presentation,
                reason: "pipeline \(reason)",
                forceLyricsReload: forceLyricsReload
            )
        }

        remember(presentation: presentation, contentState: contentState)
    }

    /// Progress-only tick. `PlaybackCoordinator` no longer republishes the
    /// whole presentation for elapsed-time changes, so the pipeline is nudged
    /// directly to keep the displayed clock anchored to the transport.
    func syncProgressOnly(_ presentation: NowPlayingPresentation) {
        syncPlaybackState(presentation)
        remember(presentation: presentation, contentState: contentState(for: presentation))
    }

    private func syncPlaybackState(_ presentation: NowPlayingPresentation) {
        guard let lyricsVM else { return }

        // An offset-only change (e.g. user edited the external override) does not
        // alter the lyrics content signature, so it would otherwise be treated as
        // a plain sync and never re-push renderer config. Reconcile the external
        // offset here so offset edits refresh the lyrics config immediately.
        if presentation.source.isExternal {
            lyricsVM.applyExternalLyricsOffset(presentation.externalLyricsTimeOffsetMs ?? 0)
        }

        let currentTime = presentation.lyricsCurrentTime
        let seekRevision = playbackCoordinator?.lyricsSeekRevision
        let explicitSeek = seekRevision != nil && seekRevision != lastSeekRevision
        let restarted = (lastSyncedTime ?? 0) > 1.0
            && currentTime < 0.2
            && presentation.isPlaying
        if restarted {
            // A same-track replay has no content-state change, but it is still
            // a new lyric entrance. Reinstall the document so MelismaKit can
            // start its bottom-to-target spring instead of treating the reset
            // as an immediate seek on the settled stack.
            applyPresentation(
                presentation,
                reason: "playback restarted",
                forceLyricsReload: true
            )
            return
        }
        let isPlaying = presentation.effectiveLyricsIsPlaying
        let rendererBecameReady = lastIsPlaying == false && isPlaying
            && lastTransportIsPlaying == true && presentation.isPlaying
        // Assert the transport state on every sample instead of only on a
        // transition. Another caller (a scrub preview, a reactivated surface or
        // a stale snapshot) can start the native clock without this pipeline
        // seeing a transition; the paused state then never reaches the surface
        // and the lyrics keep advancing on their own. The call is idempotent.
        lyricsVM.setPlaying(isPlaying)
        // A paused surface freezes at its predicted time, which can diverge
        // from the transport after a renderer re-anchor, a missed seek or a
        // free-running clock. Rebase it while paused so the next sample cannot
        // leave the lyrics stranded at the wrong position.
        let surfaceTime = LyricsSurfaceManager.shared.currentPlaybackTime
        let pausedDivergence = !isPlaying && abs(surfaceTime - currentTime) > 0.5
        let timeChanged = lastSyncedTime == nil || abs((lastSyncedTime ?? 0) - currentTime) >= 0.01
        if explicitSeek || rendererBecameReady || pausedDivergence || timeChanged {
            lyricsVM.syncTime(currentTime, force: explicitSeek || rendererBecameReady || pausedDivergence)
        }
    }

    private func remember(
        presentation: NowPlayingPresentation,
        contentState: ContentState
    ) {
        lastContentState = contentState
        lastHadTrack = presentation.hasTrack
        lastIsPlaying = presentation.effectiveLyricsIsPlaying
        lastTransportIsPlaying = presentation.isPlaying
        lastSyncedTime = presentation.lyricsCurrentTime
        lastSeekRevision = playbackCoordinator?.lyricsSeekRevision
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
