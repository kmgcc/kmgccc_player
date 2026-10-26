import Foundation

nonisolated struct MusicCompletionStatus: Codable, Sendable {
    var isLoading: Bool
    var completed: Int
    var failed: Int
    var remaining: Int
    var isPaused: Bool
    var currentTrackID: UUID?
    var currentTrackTitle: String?
    var lastError: String?
}

private actor MusicCompletionLedger {
    nonisolated struct State: Codable, Sendable {
        var version = 1
        var scanned: [String: String] = [:]
        var failures: [String: String] = [:]
        var paused = false
        /// When each failure is tried again; a failure without one is due now.
        var retries: [String: Retry]?
    }
    nonisolated struct Retry: Codable, Sendable {
        var attempts: Int
        var next: Date
    }
    let url: URL
    init(url: URL) { self.url = url }
    func load() -> State {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(State.self, from: data), state.version == 1 else { return State() }
        return state
    }
    func save(_ state: State) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
}

/// A persistent idle backlog, worked one album at a time and serially, so it
/// stays gentle. A negative match or a final error is a completed scan;
/// network failures are tried again later with a growing delay.
@MainActor
final class MusicEnrichmentWorkSource: BackgroundWorkSource {
    let sourceID: String
    let owner: BackgroundWorkOwner
    var domain: BackgroundWorkDomain { .metadataCompletion }
    var resources: BackgroundWorkResources { [.network, .disk] }
    private let service: MusicEnrichmentService
    private let ledger: MusicCompletionLedger
    private let tracks: @MainActor () -> [Track]
    private let revision: @MainActor () -> Int
    private let score: @MainActor (UUID) -> Double
    private let wake: @MainActor () -> Void
    private var state = MusicCompletionLedger.State()
    private var ready = false
    private var closed = false
    private var cachedRevision = -1
    private var ordered: [Track] = []
    private var fingerprints: [UUID: String] = [:]
    private var albumKeys: [UUID: String] = [:]
    private var forced = Set<UUID>()
    private var runningID: UUID?
    private var runningContext: BackgroundWorkContext?
    private var loadTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var lastError: String?

    init(libraryID: UUID, owner: BackgroundWorkOwner, rootURL: URL,
         service: MusicEnrichmentService, tracks: @escaping @MainActor () -> [Track],
         revision: @escaping @MainActor () -> Int,
         score: @escaping @MainActor (UUID) -> Double, wake: @escaping @MainActor () -> Void) {
        self.sourceID = "music-completion:\(libraryID)"
        self.owner = owner
        self.service = service
        self.tracks = tracks
        self.revision = revision
        self.score = score
        self.wake = wake
        self.ledger = MusicCompletionLedger(url: rootURL.appendingPathComponent("completion-v1.json"))
        loadTask = Task { [weak self, ledger] in
            let loaded = await ledger.load()
            guard let self, !self.closed else { return }
            self.state = loaded
            self.ready = true
            self.scheduleRetry()
            self.wake()
        }
    }

    func prepare() async { await loadTask?.value }

    var status: MusicCompletionStatus {
        refreshOrder()
        let completed = ordered.filter { state.scanned[$0.id.uuidString] == fingerprints[$0.id] }.count
        let failed = ordered.filter { state.failures[$0.id.uuidString] != nil }.count
        return MusicCompletionStatus(isLoading: !ready, completed: completed, failed: failed,
            remaining: max(0, ordered.count - completed - failed), isPaused: state.paused,
            currentTrackID: runningID, currentTrackTitle: ordered.first { $0.id == runningID }?.title,
            lastError: lastError)
    }
    var progress: BackgroundWorkProgress {
        let value = status
        return BackgroundWorkProgress(completed: value.completed, failed: value.failed, remaining: value.remaining)
    }
    func enqueue(trackIDs: [UUID]? = nil, force: Bool = false) {
        guard !closed else { return }
        guard ready else {
            Task { [weak self] in
                await self?.loadTask?.value
                self?.enqueue(trackIDs: trackIDs, force: force)
            }
            return
        }
        if force {
            let ids = trackIDs ?? tracks().map(\.id)
            for id in ids {
                state.scanned[id.uuidString] = nil
                state.failures[id.uuidString] = nil
                state.retries?[id.uuidString] = nil
                forced.insert(id)
            }
            persist()
        }
        cachedRevision = -1
        wake()
    }
    func setPaused(_ paused: Bool) {
        guard !closed else { return }
        guard ready else {
            Task { [weak self] in await self?.loadTask?.value; self?.setPaused(paused) }
            return
        }
        state.paused = paused
        runningContext?.setPaused(paused)
        persist()
        wake()
    }
    func retryFailures() {
        guard !closed else { return }
        guard ready else {
            Task { [weak self] in await self?.loadTask?.value; self?.retryFailures() }
            return
        }
        state.failures.removeAll()
        state.retries = nil
        lastError = nil
        persist()
        wake()
    }
    func flush() async { await persistenceTask?.value }

    func close() {
        closed = true
        loadTask?.cancel()
        retryTask?.cancel()
        runningContext?.cancel()
    }
    func hasWork(priority: BackgroundWorkPriority, excluding: Set<String>) -> Bool {
        candidate(priority: priority, excluding: excluding) != nil
    }
    nonisolated private struct Item: Sendable {
        var id: UUID
        var query: MusicEnrichmentQuery
        var fingerprint: String
        var force: Bool
    }

    /// One unit is an album: its motion artwork is looked up once for all of
    /// its pending songs, then each song's metadata is completed in turn.
    func nextUnit(priority: BackgroundWorkPriority, excluding: Set<String>) -> BackgroundWorkUnit? {
        guard let track = candidate(priority: priority, excluding: excluding) else { return nil }
        runningID = track.id
        let albumKey = albumKeys[track.id]
        let siblings = albumKey == nil ? [] : ordered.filter { other in
            other.id != track.id && albumKeys[other.id] == albumKey && isPending(other, excluding: excluding)
        }
        let items = ([track] + siblings.prefix(Self.maxAlbumUnitSize - 1)).map {
            Item(id: $0.id, query: Self.query($0), fingerprint: Self.fingerprint($0), force: forced.contains($0.id))
        }
        return BackgroundWorkUnit(id: track.id.uuidString, priority: priority) { [weak self] context in
            guard let self else { return .cancelled }
            return await self.complete(items, context: context)
        }
    }
    func unitDidEnd(unitID: String, outcome: BackgroundWorkOutcome) {
        runningID = nil
        runningContext = nil
    }
    private func complete(_ items: [Item], context: BackgroundWorkContext) async -> BackgroundWorkOutcome {
        runningContext = context
        defer { scheduleRetry() }
        var motionError: Error?
        do {
            try await context.checkpoint()
            guard !closed else { return .cancelled }
            if AppSettings.isMotionArtworkFetchEnabled {
                try await service.completeAlbumMotion(queries: items.map(\.query), context: context)
            }
        } catch is CancellationError { return .cancelled }
        catch {
            guard !closed, !Task.isCancelled else { return .cancelled }
            motionError = error
        }
        var lastFailure: String?
        for (index, item) in items.enumerated() {
            runningID = item.id
            var failure: Error?
            do {
                try await context.checkpoint()
                guard !closed else { return .cancelled }
                _ = try await service.completeIndependently(query: item.query, force: item.force, includeMotion: false, context: context)
                try await context.checkpoint()
                guard !closed else { return .cancelled }
                // A failed album lookup is retried through the album's first song.
                if index == 0 { failure = motionError }
            } catch is CancellationError { return .cancelled }
            catch {
                guard !closed, !Task.isCancelled else { return .cancelled }
                failure = error
            }
            forced.remove(item.id)
            if let message = record(failure, for: item) { lastFailure = message }
            await persistenceTask?.value
            try? await ledger.save(state)
        }
        guard let lastFailure else { return .completed }
        lastError = lastFailure
        return items.count == 1 ? .failed(lastFailure) : .completed
    }

    /// Marks a song scanned unless the network failed, in which case it waits
    /// for a later attempt. Returns the failure kept for retrying.
    private func record(_ error: Error?, for item: Item) -> String? {
        let id = item.id.uuidString
        guard let error, MusicEnrichmentHelperError.isRetryable(error) else {
            if let error {
                Log.info("[MusicEnrichment] key=\(item.query.key) event=skipped errorType=\(String(describing: type(of: error)))", category: .library)
            }
            state.scanned[id] = item.fingerprint
            state.failures[id] = nil
            state.retries?[id] = nil
            return nil
        }
        let attempts = (state.retries?[id]?.attempts ?? 0) + 1
        state.failures[id] = error.localizedDescription
        state.retries = state.retries ?? [:]
        state.retries?[id] = MusicCompletionLedger.Retry(attempts: attempts, next: Date().addingTimeInterval(Self.retryDelay(attempts)))
        return error.localizedDescription
    }

    /// 10 minutes, then an hour, six hours, and once a day from then on.
    private static func retryDelay(_ attempts: Int) -> TimeInterval {
        switch attempts {
        case ...1: 10 * 60
        case 2: 60 * 60
        case 3: 6 * 60 * 60
        default: 24 * 60 * 60
        }
    }

    /// Wakes the scheduler when the earliest waiting failure becomes due.
    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = nil
        let waiting = state.failures.keys.compactMap { state.retries?[$0]?.next }
        guard !closed, let next = waiting.min(), next > Date() else { return }
        let delay = next.timeIntervalSinceNow + 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.closed else { return }
            self.wake()
        }
    }

    private func isRetryDue(_ id: String) -> Bool {
        guard state.failures[id] != nil else { return false }
        return (state.retries?[id]?.next ?? .distantPast) <= Date()
    }

    private func candidate(priority: BackgroundWorkPriority, excluding: Set<String>) -> Track? {
        guard priority == .idleBatch, ready, !closed, !state.paused, runningID == nil else { return nil }
        refreshOrder()
        return ordered.first { isPending($0, excluding: excluding) }
    }
    private func isPending(_ track: Track, excluding: Set<String>) -> Bool {
        let id = track.id.uuidString
        guard !excluding.contains(id) else { return false }
        if state.failures[id] != nil { return isRetryDue(id) }
        return state.scanned[id] != fingerprints[track.id]
    }
    private func refreshOrder() {
        let current = revision()
        guard cachedRevision != current else { return }
        cachedRevision = current
        let candidates = tracks()
        fingerprints = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, Self.fingerprint($0)) })
        albumKeys = Dictionary(uniqueKeysWithValues: candidates.compactMap { track in Self.albumKey(track).map { (track.id, $0) } })
        let ranked: [(track: Track, preference: Double)] = candidates.map { track in
            (track: track, preference: score(track.id))
        }
        let sorted = ranked.sorted { left, right in
            if left.preference != right.preference { return left.preference > right.preference }
            return left.track.id.uuidString < right.track.id.uuidString
        }
        ordered = sorted.map { $0.track }
    }
    private func persist() {
        let snapshot = state
        let previous = persistenceTask
        persistenceTask = Task { [ledger] in
            await previous?.value
            try? await ledger.save(snapshot)
        }
    }
    static func query(_ track: Track) -> MusicEnrichmentQuery {
        MusicEnrichmentQuery(key: "track:\(track.id.uuidString)", title: track.title,
            artist: track.artist, album: track.album, duration: track.duration,
            storedMotionArtwork: track.motionArtwork, albumArtist: track.albumArtist)
    }
    /// Bounds a unit so pausing and progress stay responsive on huge albums.
    private static let maxAlbumUnitSize = 40

    /// Songs share motion artwork when they share an album name and album artist.
    static func albumKey(_ track: Track) -> String? {
        let identity = MusicEnrichmentRecord(query: query(track)).motionAlbumIdentity
        return identity?.fallbackKey ?? identity?.key
    }
    private static func fingerprint(_ track: Track) -> String {
        MusicEnrichmentStore.digest("\(track.title)\u{0}\(track.artist)\u{0}\(track.album)\u{0}\(track.albumArtist ?? "")\u{0}\(track.duration)")
    }
}
