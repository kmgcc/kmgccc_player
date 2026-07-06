//
//  LyricsPlaybackPipeline.swift
//  myPlayer2
//
//  Stable playback-to-lyrics state pipeline.
//

import Foundation

@MainActor
final class LyricsPlaybackPipeline {
    private weak var lyricsVM: LyricsViewModel?
    private weak var playbackCoordinator: PlaybackCoordinator?

    private var lastContentSignature: String?
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
        let oldSignature = contentSignature(for: oldPresentation)
        let newSignature = contentSignature(for: newPresentation)
        let contentChanged = lastContentSignature != newSignature || oldSignature != newSignature
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
        remember(presentation: newPresentation, signature: newSignature)
    }

    private func applyPresentation(
        _ presentation: NowPlayingPresentation,
        reason: String,
        forceLyricsReload: Bool
    ) {
        guard let lyricsVM else { return }
        let signature = contentSignature(for: presentation)

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

        remember(presentation: presentation, signature: signature)
    }

    private func syncPlaybackState(_ presentation: NowPlayingPresentation) {
        guard let lyricsVM else { return }

        let currentTime = presentation.lyricsCurrentTime
        if lastSyncedTime == nil || abs((lastSyncedTime ?? 0) - currentTime) >= 0.01 {
            lyricsVM.syncTime(currentTime)
        }

        if lastIsPlaying != presentation.isPlaying {
            lyricsVM.setPlaying(presentation.isPlaying)
        }
    }

    private func remember(
        presentation: NowPlayingPresentation,
        signature: String
    ) {
        lastContentSignature = signature
        lastHadTrack = presentation.hasTrack
        lastIsPlaying = presentation.isPlaying
        lastSyncedTime = presentation.lyricsCurrentTime
    }

    private func contentSignature(for presentation: NowPlayingPresentation) -> String {
        switch presentation.source {
        case .local:
            let track = presentation.localTrack
            return [
                "local",
                track?.id.uuidString ?? "nil",
                presentation.lyricsIdentity ?? "nil",
                textSignature(presentation.lyricsText),
                textSignature(track?.ttmlLyricText),
                textSignature(track?.lyricsText),
                track?.ttmlLyricsFileName ?? "no-ttml-file",
                track?.lyricsFileName ?? "no-lyrics-file",
            ].joined(separator: "|")
        case .appleMusic, .systemNowPlaying:
            return [
                presentation.source.rawValue,
                presentation.externalStableKey ?? "nil",
                presentation.lyricsIdentity ?? "nil",
                textSignature(presentation.lyricsText),
                presentation.externalLyricsStatusMessage ?? "nil",
            ].joined(separator: "|")
        }
    }

    private func textSignature(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "empty" }
        let head = String(text.prefix(16))
        let tail = String(text.suffix(16))
        return "\(text.count):\(head):\(tail)"
    }
}
