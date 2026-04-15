//
//  ImportEnrichmentService.swift
//  myPlayer2
import Foundation
import Observation
@MainActor
@Observable
final class ImportEnrichmentService {
    private let repository: LibraryRepositoryProtocol
    private let maxConcurrent: Int
    private let maxAttemptsPerPart = 2
    private let flushBatchSize = 4
    private let flushDebounceNanoseconds: UInt64 = 900_000_000

    private var queue: [ImportEnrichmentPartRequest] = []
    private var queuedRequests: Set<ImportEnrichmentPartRequest> = []
    private var runningRequests: Set<ImportEnrichmentPartRequest> = []
    private var trackByID: [UUID: Track] = [:]
    private var itemStates: [UUID: ImportEnrichmentItemState] = [:]
    private var pendingFlushPatches: [UUID: PendingTrackEnrichmentPatch] = [:]
    private var flushTask: Task<Void, Never>?
    private var isFlushing = false
    private(set) var progress = ImportEnrichmentProgressSnapshot(
        totalEnqueued: 0,
        completedCount: 0,
        failedCount: 0,
        pendingLyricsCount: 0,
        pendingCoverCount: 0,
        runningCount: 0,
        flushPendingCount: 0
    )

    var hasOutstandingWork: Bool { progress.hasOutstandingWork }

    init(repository: LibraryRepositoryProtocol, maxConcurrent: Int = 2) {
        self.repository = repository
        self.maxConcurrent = max(1, maxConcurrent)
        Log.info("[ImportEnrichment] service init", category: .import)
    }

    deinit {
        Log.info("[ImportEnrichment] service deinit", category: .import)
    }

    func enqueueTracks(_ tracks: [Track]) {
        if hasOutstandingWork == false {
            resetProgressIfIdle()
        }

        Log.info("[ImportEnrichment] queue wake requested for \(tracks.count) tracks", category: .import)

        for track in tracks {
            guard let itemState = makeInitialItemState(for: track) else { continue }
            if itemStates[track.id] == nil {
                itemStates[track.id] = itemState
            } else {
                itemStates[track.id]?.title = track.title
                itemStates[track.id]?.artist = track.artist
                itemStates[track.id]?.album = track.album
            }

            trackByID[track.id] = track

            if track.ttmlLyricText == nil {
                enqueuePart(.lyrics, for: track.id)
            } else if var state = itemStates[track.id], state.lyricsState != .completed {
                state.lyricsState = .skipped
                itemStates[track.id] = state
                Log.info(
                    "[ImportEnrichment] lyrics skipped \(state.title) - \(state.artist) | already present",
                    category: .lyrics
                )
            }

            if track.artworkData == nil {
                enqueuePart(.cover, for: track.id)
            } else if var state = itemStates[track.id], state.coverState != .completed {
                state.coverState = .skipped
                itemStates[track.id] = state
                Log.info(
                    "[ImportEnrichment] cover skipped \(state.title) - \(state.artist) | already present",
                    category: .import
                )
            }

            guard let state = itemStates[track.id] else {
                continue
            }
            Log.info(
                "[ImportEnrichment] track queued \(track.title) - \(track.artist) | lyrics=\(state.lyricsState.rawValue) cover=\(state.coverState.rawValue)",
                category: .import
            )
        }

        refreshProgress()
        drainQueueIfPossible()
        diagnoseStalledQueue(context: "enqueue")
    }

    private func makeInitialItemState(for track: Track) -> ImportEnrichmentItemState? {
        let needsLyrics = track.ttmlLyricText == nil
        let needsCover = track.artworkData == nil
        guard needsLyrics || needsCover else { return nil }

        return ImportEnrichmentItemState(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            lyricsState: needsLyrics ? .pending : .skipped,
            coverState: needsCover ? .pending : .skipped,
            lyricAttempts: 0,
            coverAttempts: 0
        )
    }

    private func enqueuePart(_ part: ImportEnrichmentPart, for trackID: UUID) {
        let request = ImportEnrichmentPartRequest(trackID: trackID, part: part)
        guard queuedRequests.contains(request) == false, runningRequests.contains(request) == false
        else { return }
        guard var state = itemStates[trackID] else { return }
        let currentState = state.state(for: part)
        guard currentState == .pending || currentState == .failed else { return }

        state.setState(.pending, for: part)
        itemStates[trackID] = state
        queue.append(request)
        queuedRequests.insert(request)
        Log.info(
            "[ImportEnrichment] \(part.rawValue) enqueued \(state.title) - \(state.artist)",
            category: part == .lyrics ? .lyrics : .import
        )
    }

    private func refreshProgress() {
        let values = Array(itemStates.values)
        let completedCount = values.filter(\.isTerminal).count
        let failedCount = values.filter(\.hasTerminalFailure).count
        let pendingLyricsCount = values.filter {
            $0.lyricsState == .pending || $0.lyricsState == .running
        }.count
        let pendingCoverCount = values.filter {
            $0.coverState == .pending || $0.coverState == .running
        }.count
        let flushPendingCount = values.reduce(0) { $0 + $1.flushPendingPartCount }

        progress = ImportEnrichmentProgressSnapshot(
            totalEnqueued: values.count,
            completedCount: completedCount,
            failedCount: failedCount,
            pendingLyricsCount: pendingLyricsCount,
            pendingCoverCount: pendingCoverCount,
            runningCount: runningRequests.count,
            flushPendingCount: flushPendingCount
        )
    }

    private func resetProgressIfIdle() {
        flushTask?.cancel()
        flushTask = nil
        queue.removeAll()
        queuedRequests.removeAll()
        runningRequests.removeAll()
        trackByID.removeAll()
        itemStates.removeAll()
        pendingFlushPatches.removeAll()
        isFlushing = false
        progress = ImportEnrichmentProgressSnapshot(
            totalEnqueued: 0,
            completedCount: 0,
            failedCount: 0,
            pendingLyricsCount: 0,
            pendingCoverCount: 0,
            runningCount: 0,
            flushPendingCount: 0
        )
    }

    private func drainQueueIfPossible() {
        if queue.isEmpty == false {
            Log.debug(
                "[ImportEnrichment] queue wake | queued=\(queue.count) running=\(runningRequests.count)",
                category: .import
            )
        }
        while runningRequests.count < maxConcurrent, queue.isEmpty == false {
            let request = queue.removeFirst()
            queuedRequests.remove(request)

            guard let track = trackByID[request.trackID], var state = itemStates[request.trackID] else {
                continue
            }

            if request.part == .lyrics, track.ttmlLyricText != nil {
                state.setState(.skipped, for: .lyrics)
                itemStates[request.trackID] = state
                Log.info(
                    "[ImportEnrichment] lyrics skipped \(state.title) - \(state.artist) | already present",
                    category: .lyrics
                )
                refreshProgress()
                continue
            }

            if request.part == .cover, track.artworkData != nil {
                state.setState(.skipped, for: .cover)
                itemStates[request.trackID] = state
                Log.info(
                    "[ImportEnrichment] cover skipped \(state.title) - \(state.artist) | already present",
                    category: .import
                )
                refreshProgress()
                continue
            }

            state.setState(.running, for: request.part)
            state.incrementAttempts(for: request.part)
            itemStates[request.trackID] = state
            runningRequests.insert(request)
            refreshProgress()
            start(request: request, track: track, state: state)
        }
        diagnoseStalledQueue(context: "drain")
    }

    private func start(
        request: ImportEnrichmentPartRequest,
        track: Track,
        state: ImportEnrichmentItemState
    ) {
        let title = state.title
        let artist = state.artist
        let album = state.album
        let duration = track.duration > 0 ? track.duration : nil
        let attempt = state.attempts(for: request.part)
        Log.info(
            "[ImportEnrichment] \(request.part.rawValue) started \(title) - \(artist) | attempt \(attempt)/\(maxAttemptsPerPart)",
            category: request.part == .lyrics ? .lyrics : .import
        )

        Task(priority: .utility) {
            let taskStart = ContinuousClock.now

            switch request.part {
            case .lyrics:
                let outcome = await ImportEnrichmentWorker.fetchLyrics(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration
                )
                await self.completeLyrics(request: request, outcome: outcome)
            case .cover:
                let outcome = await ImportEnrichmentWorker.fetchCover(
                    artist: artist,
                    album: album
                )
                await self.completeCover(request: request, outcome: outcome)
            }

            let elapsed = taskStart.duration(to: ContinuousClock.now)
            let elapsedMs = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
            Log.info(
                "[ImportEnrichment] \(request.part.rawValue) task end \(title) - \(artist) | \(String(format: "%.1f", elapsedMs))ms",
                category: request.part == .lyrics ? .lyrics : .import
            )
        }
    }

    private func completeLyrics(
        request: ImportEnrichmentPartRequest,
        outcome: ImportLyricsLookupOutcome
    ) async {
        guard let track = trackByID[request.trackID], var state = itemStates[request.trackID] else {
            finish(request)
            return
        }

        var shouldRequeue = false
        switch outcome {
        case .completed(let ttml):
            if track.ttmlLyricText == nil {
                bufferFlushPatch(
                    trackID: request.trackID,
                    title: state.title,
                    artist: state.artist
                ) { patch in
                    patch.ttmlLyricText = ttml
                    patch.lyricShouldFlush = true
                }
                state.setState(.flushPending, for: .lyrics)
                Log.info(
                    "[ImportEnrichment] lyrics buffered \(state.title) - \(state.artist)",
                    category: .lyrics
                )
            } else {
                state.setState(.skipped, for: .lyrics)
                Log.info(
                    "[ImportEnrichment] lyrics skipped \(state.title) - \(state.artist) | already filled before save",
                    category: .lyrics
                )
            }
        case .noResults:
            state.setState(.noResults, for: .lyrics)
            Log.warning(
                "[ImportEnrichment] lyrics no-results \(state.title) - \(state.artist)",
                category: .lyrics
            )
        case .failed(let message):
            shouldRequeue = shouldRetry(part: .lyrics, state: state)
            if shouldRequeue {
                state.setState(.pending, for: .lyrics)
                Log.warning(
                    "[ImportEnrichment] lyrics failed \(state.title) - \(state.artist) | retrying: \(message)",
                    category: .lyrics
                )
            } else {
                state.setState(.failed, for: .lyrics)
                Log.warning(
                    "[ImportEnrichment] lyrics failed \(state.title) - \(state.artist): \(message)",
                    category: .lyrics
                )
            }
        }

        itemStates[request.trackID] = state
        scheduleFlushIfNeeded(reason: "lyrics_result")
        finish(request, requeue: shouldRequeue)
    }

    private func completeCover(
        request: ImportEnrichmentPartRequest,
        outcome: ImportCoverLookupOutcome
    ) async {
        guard let track = trackByID[request.trackID], var state = itemStates[request.trackID] else {
            finish(request)
            return
        }

        var shouldRequeue = false
        switch outcome {
        case .completed(let data):
            if track.artworkData == nil {
                bufferFlushPatch(
                    trackID: request.trackID,
                    title: state.title,
                    artist: state.artist
                ) { patch in
                    patch.artworkData = data
                    patch.coverShouldFlush = true
                }
                state.setState(.flushPending, for: .cover)
                Log.info(
                    "[ImportEnrichment] cover buffered \(state.title) - \(state.artist)",
                    category: .import
                )
            } else {
                state.setState(.skipped, for: .cover)
                Log.info(
                    "[ImportEnrichment] cover skipped \(state.title) - \(state.artist) | already filled before save",
                    category: .import
                )
            }
        case .noResults:
            state.setState(.noResults, for: .cover)
            Log.warning(
                "[ImportEnrichment] cover no-results \(state.title) - \(state.artist)",
                category: .import
            )
        case .failed(let message):
            shouldRequeue = shouldRetry(part: .cover, state: state)
            if shouldRequeue {
                state.setState(.pending, for: .cover)
                Log.warning(
                    "[ImportEnrichment] cover failed \(state.title) - \(state.artist) | retrying: \(message)",
                    category: .import
                )
            } else {
                state.setState(.failed, for: .cover)
                Log.warning(
                    "[ImportEnrichment] cover failed \(state.title) - \(state.artist): \(message)",
                    category: .import
                )
            }
        }

        itemStates[request.trackID] = state
        scheduleFlushIfNeeded(reason: "cover_result")
        finish(request, requeue: shouldRequeue)
    }

    private func shouldRetry(part: ImportEnrichmentPart, state: ImportEnrichmentItemState) -> Bool {
        state.attempts(for: part) < maxAttemptsPerPart
    }

    private func bufferFlushPatch(
        trackID: UUID,
        title: String,
        artist: String,
        mutate: (inout PendingTrackEnrichmentPatch) -> Void
    ) {
        var patch = pendingFlushPatches[trackID] ?? PendingTrackEnrichmentPatch(trackID: trackID)
        mutate(&patch)
        pendingFlushPatches[trackID] = patch
        Log.info(
            "[ImportEnrichment] batch buffered \(title) - \(artist) | pendingTracks=\(pendingFlushPatches.count)",
            category: .import
        )
    }

    private func scheduleFlushIfNeeded(reason: String) {
        guard pendingFlushPatches.isEmpty == false else { return }

        if pendingFlushPatches.count >= flushBatchSize {
            flushTask?.cancel()
            flushTask = nil
            Task { @MainActor in
                await flushBufferedUpdates(reason: "threshold:\(reason)")
            }
            return
        }

        if queue.isEmpty && runningRequests.isEmpty {
            flushTask?.cancel()
            flushTask = nil
            Task { @MainActor in
                await flushBufferedUpdates(reason: "idle:\(reason)")
            }
            return
        }

        guard flushTask == nil else { return }
        flushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: flushDebounceNanoseconds)
            await flushBufferedUpdates(reason: "debounce:\(reason)")
        }
    }

    private func flushBufferedUpdates(reason: String) async {
        guard isFlushing == false else { return }
        guard pendingFlushPatches.isEmpty == false else { return }

        isFlushing = true
        flushTask?.cancel()
        flushTask = nil

        let patches = pendingFlushPatches
        let trackIDs = Array(patches.keys).sorted { $0.uuidString < $1.uuidString }
        Log.info(
            "[ImportEnrichment] batch flush start reason=\(reason) tracks=\(trackIDs.count)",
            category: .import
        )

        struct PendingRevert {
            let lyrics: String?
            let artworkData: Data?
        }

        var touchedTracks: [Track] = []
        var revertByTrackID: [UUID: PendingRevert] = [:]
        var effectivePatches: [UUID: PendingTrackEnrichmentPatch] = [:]

        for trackID in trackIDs {
            guard let track = trackByID[trackID], let patch = patches[trackID] else { continue }
            var effectivePatch = patch
            revertByTrackID[trackID] = PendingRevert(
                lyrics: track.ttmlLyricText,
                artworkData: track.artworkData
            )

            if patch.lyricShouldFlush {
                if track.ttmlLyricText == nil, let ttml = patch.ttmlLyricText {
                    track.ttmlLyricText = ttml
                } else {
                    effectivePatch.ttmlLyricText = nil
                    effectivePatch.lyricShouldFlush = false
                }
            }
            if patch.coverShouldFlush {
                if track.artworkData == nil, let artworkData = patch.artworkData {
                    track.artworkData = artworkData
                } else {
                    effectivePatch.artworkData = nil
                    effectivePatch.coverShouldFlush = false
                }
            }

            if effectivePatch.lyricShouldFlush || effectivePatch.coverShouldFlush {
                touchedTracks.append(track)
                effectivePatches[trackID] = effectivePatch
            } else {
                if var state = itemStates[trackID] {
                    if patch.lyricShouldFlush, state.lyricsState == .flushPending {
                        state.lyricsState = .skipped
                    }
                    if patch.coverShouldFlush, state.coverState == .flushPending {
                        state.coverState = .skipped
                    }
                    itemStates[trackID] = state
                    if state.isTerminal {
                        trackByID[trackID] = nil
                    }
                }
                pendingFlushPatches.removeValue(forKey: trackID)
            }
        }

        guard !touchedTracks.isEmpty else {
            refreshProgress()
            Log.info(
                "[ImportEnrichment] batch flush complete reason=\(reason) persisted=0 failed=0",
                category: .import
            )
            isFlushing = false
            return
        }

        let lyricOnlyTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return patch.lyricShouldFlush && !patch.coverShouldFlush
        }
        let coverOnlyTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return !patch.lyricShouldFlush && patch.coverShouldFlush
        }
        let lyricAndCoverTracks = touchedTracks.filter { track in
            guard let patch = effectivePatches[track.id] else { return false }
            return patch.lyricShouldFlush && patch.coverShouldFlush
        }

        var persistedTrackIDs: Set<UUID> = []
        var failedTrackIDs: Set<UUID> = []

        if !lyricOnlyTracks.isEmpty {
            let result = await repository.persistTrackMetaAndLyrics(lyricOnlyTracks, reason: "importEnrichmentLyrics")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }
        if !coverOnlyTracks.isEmpty {
            let result = await repository.persistTrackMetaAndArtwork(coverOnlyTracks, reason: "importEnrichmentArtwork")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }
        if !lyricAndCoverTracks.isEmpty {
            let result = await repository.persistTrackMetaLyricsAndArtwork(lyricAndCoverTracks, reason: "importEnrichmentLyricsArtwork")
            persistedTrackIDs.formUnion(result.persistedTrackIDs)
            failedTrackIDs.formUnion(result.failedTrackIDs)
        }

        for trackID in persistedTrackIDs {
            guard let patch = effectivePatches[trackID], var state = itemStates[trackID] else { continue }
            if patch.lyricShouldFlush, state.lyricsState == .flushPending {
                state.lyricsState = .completed
            }
            if patch.coverShouldFlush, state.coverState == .flushPending {
                state.coverState = .completed
            }
            itemStates[trackID] = state
            pendingFlushPatches.removeValue(forKey: trackID)
            if state.isTerminal {
                trackByID[trackID] = nil
            }
        }

        for trackID in failedTrackIDs {
            guard let patch = effectivePatches[trackID], let revert = revertByTrackID[trackID] else { continue }
            if let track = trackByID[trackID] {
                track.ttmlLyricText = revert.lyrics
                track.artworkData = revert.artworkData
            }
            if var state = itemStates[trackID] {
                if patch.lyricShouldFlush, state.lyricsState == .flushPending {
                    state.lyricsState = .failed
                }
                if patch.coverShouldFlush, state.coverState == .flushPending {
                    state.coverState = .failed
                }
                itemStates[trackID] = state
                if state.isTerminal {
                    trackByID[trackID] = nil
                }
            }
            pendingFlushPatches.removeValue(forKey: trackID)
        }

        refreshProgress()
        Log.info(
            "[ImportEnrichment] batch flush complete reason=\(reason) persisted=\(persistedTrackIDs.count) failed=\(failedTrackIDs.count)",
            category: .import
        )
        if !persistedTrackIDs.isEmpty {
            Log.info(
                "[ImportEnrichment] visible refresh notified for \(persistedTrackIDs.count) persisted tracks",
                category: .import
            )
            Log.info(
                "[ImportEnrichmentReload] flush success with \(persistedTrackIDs.count) updated tracks",
                category: .import
            )
        }
        if !failedTrackIDs.isEmpty {
            Log.warning(
                "[ImportEnrichment] persistence flush failed for \(failedTrackIDs.count) tracks",
                category: .import
            )
        }

        isFlushing = false

        if pendingFlushPatches.isEmpty == false {
            scheduleFlushIfNeeded(reason: "post_flush")
        }
    }

    private func diagnoseStalledQueue(context: String) {
        if queue.isEmpty == false && runningRequests.isEmpty {
            Log.warning(
                "[ImportEnrichment] queue stalled after \(context) | queued=\(queue.count) running=0",
                category: .import
            )
        }
    }

    private func finish(_ request: ImportEnrichmentPartRequest, requeue: Bool = false) {
        runningRequests.remove(request)

        if requeue {
            queue.append(request)
            queuedRequests.insert(request)
        }

        Log.debug(
            "[ImportEnrichment] finish \(request.part.rawValue) | requeue=\(requeue) queued=\(queue.count) running=\(runningRequests.count)",
            category: .import
        )

        refreshProgress()

        if let state = itemStates[request.trackID], state.isTerminal {
            trackByID[request.trackID] = nil
        }

        if queue.isEmpty && runningRequests.isEmpty {
            scheduleFlushIfNeeded(reason: "queue_idle")
        }
        drainQueueIfPossible()
    }
}
