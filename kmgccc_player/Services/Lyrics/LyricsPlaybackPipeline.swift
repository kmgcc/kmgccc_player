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
                isPlaying: presentation.isPlaying,
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
            && presentation.effectiveLyricsIsPlaying
        if restarted {
            // A same-track replay has no content-state change, but it is still
            // a new lyric entrance. Reinstall the document so NativeLyrics can
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
        if lastIsPlaying != isPlaying {
            // Freeze/restart the native presentation clock at the transport
            // transition before feeding it the next (possibly stale) media
            // sample. This preserves the audio-output-delay/Bluetooth timing
            // already encoded in lyricsCurrentTime without letting callback
            // ordering move the lyric highlight backwards.
            lyricsVM.setPlaying(isPlaying)
        }
        if explicitSeek || lastSyncedTime == nil || abs((lastSyncedTime ?? 0) - currentTime) >= 0.01 {
            lyricsVM.syncTime(currentTime, force: explicitSeek)
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
