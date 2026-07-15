//
//  LyricsPlaybackPipeline.swift
//  myPlayer2
//
//  Stable playback-to-lyrics state pipeline.
//

import Foundation
import CryptoKit

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
        signature: String
    ) {
        lastContentSignature = signature
        lastHadTrack = presentation.hasTrack
        lastIsPlaying = presentation.effectiveLyricsIsPlaying
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
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
