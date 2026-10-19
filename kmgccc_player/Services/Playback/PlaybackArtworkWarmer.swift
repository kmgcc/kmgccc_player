//
//  PlaybackArtworkWarmer.swift
//  myPlayer2
//
//  Playback-window artwork preloading.
//

import Foundation

/// Preloads the current track and a small neighbouring queue window.
///
/// The warmer owns only its cancellable warm-up handle and deduplication key;
/// playback state remains owned by `PlayerViewModel` and presentation remains
/// owned by `PlaybackCoordinator`. The warm-up runs as upcoming work of the
/// App background scheduler, so it never competes with idle preparation.
@MainActor
final class PlaybackArtworkWarmer {
    private let artworkCache: TrackArtworkCache
    private weak var scheduler: BackgroundWorkScheduler?
    private var owner: BackgroundWorkOwner = .app
    private var handle: BackgroundTaskHandle?
    private var signature: String?
    private var presentationSignature: String?

    init(artworkCache: TrackArtworkCache) {
        self.artworkCache = artworkCache
    }

    /// Connects the warmer to the App scheduler. Until then nothing is warmed;
    /// the next presentation update after binding starts the warm-up.
    func bind(scheduler: BackgroundWorkScheduler, owner: BackgroundWorkOwner) {
        self.scheduler = scheduler
        self.owner = owner
        reset()
    }

    func update(
        activeSource: PlaybackSource,
        presentation: NowPlayingPresentation,
        queue: @autoclosure () -> [Track]
    ) {
        guard activeSource == .local, let currentTrack = presentation.localTrack else {
            reset()
            return
        }
        guard let scheduler else { return }

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
                : nil
            return track.trackArtworkSource(fallbackData: fallbackData)
        }

        guard !sources.isEmpty else {
            handle?.cancel()
            handle = nil
            signature = nil
            return
        }

        let nextSignature = sources.map(\.sourceKey).joined(separator: "||")
        guard nextSignature != signature else { return }

        signature = nextSignature
        handle?.cancel()
        let artworkCache = artworkCache
        handle = scheduler.submitWork(
            owner: owner,
            domain: .playbackArtwork,
            priority: .upcoming,
            resources: [.compute, .disk]
        ) { context in
            await artworkCache.warmPlaybackArtwork(
                for: sources,
                reason: "playback-current-window",
                context: context
            )
        }
    }

    func reset() {
        handle?.cancel()
        handle = nil
        signature = nil
        presentationSignature = nil
    }
}
