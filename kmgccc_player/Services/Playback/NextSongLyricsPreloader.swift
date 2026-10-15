//
//  NextSongLyricsPreloader.swift
//  myPlayer2
//
//  Reads the next song's lyric sidecar ahead of the track change.
//

import Foundation

/// Reads lyric sidecar files without touching the main actor. Both the
/// playing song's hydration and the next song's preload use it, so the
/// normalization rules stay in one place.
nonisolated enum LyricsSidecarReader {
    nonisolated static func loadTTML(ttmlURL: URL?, fallbackURL: URL?) -> String? {
        if let ttmlURL,
           let text = try? String(contentsOf: ttmlURL, encoding: .utf8),
           let ttml = LyricsFormatSupport.normalizedTTMLText(text) {
            return ttml
        }
        if let fallbackURL,
           fallbackURL.lastPathComponent.lowercased().hasSuffix(".ttml"),
           let text = try? String(contentsOf: fallbackURL, encoding: .utf8),
           let ttml = LyricsFormatSupport.normalizedTTMLText(text) {
            return ttml
        }
        return nil
    }
}

/// Reads and normalizes the next queued song's sidecar lyrics as upcoming
/// work of the App scheduler, so the lyrics are on the song when it starts.
/// The result goes to the same place the playing song's hydration writes: the
/// track's own lyric text, which the presentation reads from. Only local
/// files are read; nothing is searched online.
@MainActor
final class NextSongLyricsPreloader {
    private weak var scheduler: BackgroundWorkScheduler?
    private var owner: BackgroundWorkOwner = .app
    private var handle: BackgroundTaskHandle?
    private var lastCurrentTrackID: UUID?
    private var preloadedTrackID: UUID?
    private let trackLookup: @MainActor (UUID) -> Track?

    init(trackLookup: @escaping @MainActor (UUID) -> Track?) {
        self.trackLookup = trackLookup
    }

    func bind(scheduler: BackgroundWorkScheduler, owner: BackgroundWorkOwner) {
        self.scheduler = scheduler
        self.owner = owner
        reset()
    }

    /// Called with each presentation update; work happens only when the
    /// current song changed.
    func update(
        activeSource: PlaybackSource,
        currentTrack: Track?,
        queue: @autoclosure () -> [Track]
    ) {
        guard activeSource == .local, let currentTrack, let scheduler else {
            reset()
            return
        }
        guard currentTrack.id != lastCurrentTrackID else { return }
        lastCurrentTrackID = currentTrack.id
        if let oldPreloadedID = preloadedTrackID, oldPreloadedID != currentTrack.id {
            trackLookup(oldPreloadedID)?.releaseFileBackedLyricsText()
        }
        preloadedTrackID = nil
        handle?.cancel()
        handle = nil

        let queue = queue()
        guard let index = queue.firstIndex(where: { $0.id == currentTrack.id }),
              queue.indices.contains(index + 1) else { return }
        let next = queue[index + 1]
        guard next.id != currentTrack.id, next.ttmlLyricText?.isEmpty != false else { return }
        let ttmlURL = next.resolvedTTMLURL()
        let fallbackURL = next.resolvedLyricsURL()
        guard ttmlURL != nil || fallbackURL != nil else { return }

        preloadedTrackID = next.id
        let trackID = next.id
        handle = scheduler.submitWork(
            owner: owner,
            domain: .nextSongLyrics,
            priority: .upcoming,
            resources: [.disk]
        ) { [weak self] context in
            guard (try? await context.checkpoint()) != nil else { return }
            let ttml = await Task.detached(priority: context.taskPriority) {
                LyricsSidecarReader.loadTTML(ttmlURL: ttmlURL, fallbackURL: fallbackURL)
            }.value
            guard let ttml, (try? await context.checkpoint()) != nil else { return }
            await self?.apply(ttml, toTrack: trackID)
        }
    }

    private func apply(_ ttml: String, toTrack trackID: UUID) {
        guard preloadedTrackID == trackID,
              let track = trackLookup(trackID),
              track.ttmlLyricText?.isEmpty != false else { return }
        track.ttmlLyricText = ttml
    }

    func reset() {
        handle?.cancel()
        handle = nil
        lastCurrentTrackID = nil
        if let preloadedID = preloadedTrackID {
            trackLookup(preloadedID)?.releaseFileBackedLyricsText()
        }
        preloadedTrackID = nil
    }
}
