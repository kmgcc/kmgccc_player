//
//  PlaybackArtworkWarmer.swift
//  myPlayer2
//
//  Playback-window artwork preloading.
//

import Foundation

/// Preloads the current track and a small neighbouring queue window.
///
/// The warmer owns only its cancellable preload task and deduplication key;
/// playback state remains owned by `PlayerViewModel` and presentation remains
/// owned by `PlaybackCoordinator`.
@MainActor
final class PlaybackArtworkWarmer {
    private var task: Task<Void, Never>?
    private var signature: String?
    private var presentationSignature: String?

    func update(
        activeSource: PlaybackSource,
        presentation: NowPlayingPresentation,
        queue: @autoclosure () -> [Track]
    ) {
        guard activeSource == .local, let currentTrack = presentation.localTrack else {
            reset()
            return
        }

        // Progress-only presentation updates arrive several times per second.
        // Do not rebuild the queue window or resolve artwork paths unless the
        // current artwork input actually changed. The queue is intentionally an
        // autoclosure so its array copy is skipped on this hot no-op path.
        let nextPresentationSignature = [
            currentTrack.id.uuidString,
            presentation.artworkIdentity ?? "no-artwork-identity",
            presentation.artworkDisplayTrackID?.uuidString ?? "no-display-track",
            ArtworkDataFingerprint.sampledString(for: presentation.artworkData),
            presentation.isArtworkLoading ? "loading" : "ready",
        ].joined(separator: "|")
        guard nextPresentationSignature != presentationSignature else { return }
        presentationSignature = nextPresentationSignature

        let queue = queue()

        let currentIndex = queue.firstIndex(where: { $0.id == currentTrack.id })
        var targets: [Track] = [currentTrack]
        if let currentIndex {
            for offset in 1...2 {
                let index = currentIndex + offset
                if queue.indices.contains(index) {
                    targets.append(queue[index])
                }
            }
            let previousIndex = currentIndex - 1
            if queue.indices.contains(previousIndex) {
                targets.append(queue[previousIndex])
            }
        }

        var seen = Set<UUID>()
        let sources = targets.compactMap { track -> TrackArtworkSource? in
            guard seen.insert(track.id).inserted else { return nil }
            let fallbackData = track.id == currentTrack.id
                ? presentation.artworkData
                : track.artworkData
            return track.trackArtworkSource(fallbackData: fallbackData)
        }

        guard !sources.isEmpty else {
            task?.cancel()
            task = nil
            signature = nil
            return
        }

        let nextSignature = sources.map(\.sourceKey).joined(separator: "||")
        guard nextSignature != signature else { return }

        signature = nextSignature
        task?.cancel()
        task = TrackArtworkCache.shared.preloadPlaybackArtwork(
            for: sources,
            reason: "playback-current-window"
        )
    }

    private func reset() {
        task?.cancel()
        task = nil
        signature = nil
        presentationSignature = nil
    }
}
