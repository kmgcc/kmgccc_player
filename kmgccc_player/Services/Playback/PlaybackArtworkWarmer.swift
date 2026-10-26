//
//  PlaybackArtworkWarmer.swift
//  myPlayer2
//
//  Playback-window artwork preloading.
//

import AppKit
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
    private let motionArtworkCache: MotionArtworkFirstFrameCache?
    private weak var scheduler: BackgroundWorkScheduler?
    private var owner: BackgroundWorkOwner = .app
    private var handle: BackgroundTaskHandle?
    private var signature: String?
    private var presentationSignature: String?

    init(artworkCache: TrackArtworkCache, motionArtworkCache: MotionArtworkFirstFrameCache? = nil) {
        self.artworkCache = artworkCache
        self.motionArtworkCache = motionArtworkCache
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
        queueRevision: Int = 0,
        currentQueueIndex: Int? = nil,
        queue: @autoclosure () -> [Track]
    ) {
        guard activeSource == .local, let currentTrack = presentation.localTrack else {
            reset()
            return
        }
        guard let scheduler else { return }
        let preparesMotion = presentation.isPlaying && AppSettings.shared.motionArtworkEnabled
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

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
            "queue:\(queueRevision):\(currentQueueIndex ?? -1):\(String(describing: presentation.localPlaybackOrderMode))",
            preparesMotion ? "motion" : "static",
        ].joined(separator: "|")
        guard nextPresentationSignature != presentationSignature else { return }
        presentationSignature = nextPresentationSignature

        let queue = queue()

        let currentIndex = currentQueueIndex.flatMap { index in
            queue.indices.contains(index) && queue[index].id == currentTrack.id ? index : nil
        } ?? queue.firstIndex(where: { $0.id == currentTrack.id })
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

        // The display queue is already in the shuffle session's actual order.
        // Decode only the immediate successor, and deduplicate shared square /
        // tall assets. No player or skin renderer is created by this work.
        var motionResources: [MotionArtworkResource] = []
        if preparesMotion, motionArtworkCache != nil, let currentIndex,
           queue.indices.contains(currentIndex + 1) {
            let next = queue[currentIndex + 1]
            for resource in [next.storedMotionArtworkResource, next.tallStoredMotionArtworkResource].compactMap({ $0 }) {
                if !motionResources.contains(resource) { motionResources.append(resource) }
            }
        }

        guard !sources.isEmpty || !motionResources.isEmpty else {
            handle?.cancel()
            handle = nil
            signature = nil
            return
        }

        let motionSignature = motionResources.map { "\($0.url.absoluteString):\($0.startTime):\($0.duration)" }
        let nextSignature = (sources.map(\.sourceKey) + motionSignature).joined(separator: "||")
        guard nextSignature != signature else { return }

        signature = nextSignature
        handle?.cancel()
        let artworkCache = artworkCache
        let motionArtworkCache = motionArtworkCache
        let preparedMotionResources = motionResources
        handle = scheduler.submitWork(
            owner: owner,
            domain: .playbackArtwork,
            priority: .upcoming,
            resources: [.compute, .disk]
        ) { context in
            await artworkCache.warmPlaybackArtwork(
                for: Array(sources.prefix(1)),
                reason: "playback-current-window",
                context: context
            )
            if let motionArtworkCache {
                for resource in preparedMotionResources {
                    guard (try? await context.checkpoint()) != nil else { return }
                    await motionArtworkCache.prepare(resource, context: context)
                }
            }
            await artworkCache.warmPlaybackArtwork(
                for: Array(sources.dropFirst()), reason: "playback-current-window", context: context
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
