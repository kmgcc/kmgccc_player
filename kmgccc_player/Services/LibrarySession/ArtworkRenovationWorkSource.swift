import Foundation
import Observation

nonisolated struct ArtworkRenovationState: Codable, Sendable {
    enum Result: String, Codable, Sendable { case updated, kept, failed }
    var version = 1
    /// A frozen cohort: songs imported after this upgrade already keep originals.
    var trackIDs: [UUID]?
    var results: [UUID: Result] = [:]
    var attempts: [UUID: Int] = [:]
    var retryAfter: [UUID: Date] = [:]
    var declined = false
}

private actor ArtworkRenovationLedger {
    let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> ArtworkRenovationState {
        guard FileManager.default.fileExists(atPath: url.path) else { return ArtworkRenovationState() }
        let state = try JSONDecoder().decode(ArtworkRenovationState.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return state
    }
    func save(_ state: ArtworkRenovationState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
}

/// One repair pass per library, using the existing idle scheduler and library
/// mutation owner. The pause set belongs to the process, not to the ledger.
@Observable
@MainActor
final class ArtworkRenovationWorkSource: BackgroundWorkSource {
    private static var pausedLibraries: Set<UUID> = []
    let sourceID: String
    let owner: BackgroundWorkOwner
    var domain: BackgroundWorkDomain { .artworkRenovation }
    var resources: BackgroundWorkResources { [.network, .disk] }
    private(set) var isReady = false
    private(set) var isPaused = false
    private(set) var isClosed = false
    private(set) var currentTitle: String?
    private(set) var lastError: String?
    private var state = ArtworkRenovationState()
    @ObservationIgnored private let libraryID: UUID
    @ObservationIgnored private let ledger: ArtworkRenovationLedger
    @ObservationIgnored private let tracks: @MainActor () -> [Track]
    @ObservationIgnored private let lookup: @Sendable (MusicEnrichmentQuery) async throws -> CoverCandidate?
    @ObservationIgnored private let apply: @MainActor (UUID, Data, TrackArtworkFileSnapshot?, Data?) async throws -> Bool
    @ObservationIgnored private let wake: @MainActor () -> Void
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var lookupTask: Task<CoverCandidate?, Error>?
    @ObservationIgnored private var context: BackgroundWorkContext?
    @ObservationIgnored private var runningID: UUID?
    @ObservationIgnored private var cursor = 0

    init(libraryID: UUID, owner: BackgroundWorkOwner, ledgerURL: URL,
         tracks: @escaping @MainActor () -> [Track],
         lookup: @escaping @Sendable (MusicEnrichmentQuery) async throws -> CoverCandidate?,
         apply: @escaping @MainActor (UUID, Data, TrackArtworkFileSnapshot?, Data?) async throws -> Bool,
         wake: @escaping @MainActor () -> Void) {
        self.libraryID = libraryID
        self.sourceID = "artwork-renovation:\(libraryID)"
        self.owner = owner
        self.tracks = tracks
        self.lookup = lookup
        self.apply = apply
        self.wake = wake
        self.ledger = ArtworkRenovationLedger(url: ledgerURL)
        self.isPaused = Self.pausedLibraries.contains(libraryID)
        loadTask = Task { [weak self, ledger] in
            do {
                var loaded = try await ledger.load()
                guard let self, !self.isClosed, !self.state.declined else { return }
                let current = self.tracks()
                if loaded.trackIDs == nil && !loaded.declined {
                    loaded.trackIDs = current.filter { $0.hasArtwork && $0.artworkIsUserSelected != true }
                        .map(\.id).sorted { $0.uuidString < $1.uuidString }
                    try await ledger.save(loaded)
                    guard !self.isClosed, !self.state.declined else { return }
                }
                self.state = loaded
                self.isReady = true
                self.scheduleRetry()
                self.wake()
            } catch {
                guard let self, !self.isClosed else { return }
                self.lastError = "封面翻新进度暂时无法读取"
                Log.error("[ArtworkRenovation] event=load-failed errorType=\(String(describing: type(of: error)))", category: .library)
            }
        }
    }

    var total: Int { state.trackIDs?.count ?? 0 }
    var completed: Int { state.results.count }
    var updated: Int { state.results.values.filter { $0 == .updated }.count }
    var failed: Int { state.results.values.filter { $0 == .failed }.count }
    var isDeclined: Bool { state.declined }
    var isVisible: Bool { !isClosed && (lastError != nil || (!state.declined && isReady && completed < total)) }
    var progress: BackgroundWorkProgress {
        BackgroundWorkProgress(completed: completed - failed, failed: failed, remaining: max(0, total - completed))
    }

    func prepare() async { await loadTask?.value }
    func flush() async { await persistenceTask?.value }

    func setPaused(_ paused: Bool) {
        guard !isClosed else { return }
        isPaused = paused
        if paused {
            Self.pausedLibraries.insert(libraryID)
            lookupTask?.cancel()
            context?.cancel()
        } else {
            Self.pausedLibraries.remove(libraryID)
        }
        wake()
    }

    func decline() {
        guard !isClosed else { return }
        state.declined = true
        lastError = nil
        lookupTask?.cancel()
        context?.cancel()
        retryTask?.cancel()
        persist()
        wake()
    }

    func close() {
        isClosed = true
        loadTask?.cancel()
        retryTask?.cancel()
        lookupTask?.cancel()
        context?.cancel()
    }

    func hasWork(priority: BackgroundWorkPriority, excluding: Set<String>) -> Bool {
        candidate(priority: priority, excluding: excluding) != nil
    }

    func nextUnit(priority: BackgroundWorkPriority, excluding: Set<String>) -> BackgroundWorkUnit? {
        guard let id = candidate(priority: priority, excluding: excluding) else { return nil }
        runningID = id
        return BackgroundWorkUnit(id: id.uuidString, priority: priority) { [weak self] context in
            guard let self else { return .cancelled }
            return await self.renovate(id, context: context)
        }
    }

    func unitDidEnd(unitID: String, outcome: BackgroundWorkOutcome) {
        runningID = nil
        context = nil
        lookupTask = nil
        currentTitle = nil
        scheduleRetry()
    }

    private func candidate(priority: BackgroundWorkPriority, excluding: Set<String>) -> UUID? {
        guard priority == .idleBatch, isReady, !isClosed, !isPaused, !state.declined, runningID == nil else { return nil }
        let ids = state.trackIDs ?? []
        while cursor < ids.count && state.results[ids[cursor]] != nil { cursor += 1 }
        return ids.dropFirst(cursor).first {
            state.results[$0] == nil && !excluding.contains($0.uuidString)
                && (state.retryAfter[$0] ?? .distantPast) <= Date()
        }
    }

    private func renovate(_ id: UUID, context: BackgroundWorkContext) async -> BackgroundWorkOutcome {
        self.context = context
        do {
            try await context.checkpoint()
            guard !isClosed, !isPaused, !state.declined else { return .cancelled }
            // Resolve again after deletion/reload. Keep no image buffers in the backlog.
            guard let track = tracks().first(where: { $0.id == id }), track.artworkIsUserSelected != true else {
                return await finish(id, result: .kept)
            }
            currentTitle = track.title
            let query = MusicEnrichmentWorkSource.query(track)
            let file = track.existingArtworkFileSnapshot()
            let memory = track.artworkData
            let task = Task { [lookup] in try await lookup(query) }
            lookupTask = task
            let candidate = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            lookupTask = nil
            try await context.checkpoint()
            guard !isClosed, !isPaused, !state.declined else { return .cancelled }
            guard let candidate else { return await finish(id, result: .kept) }
            guard track.artworkIsUserSelected != true,
                  track.existingArtworkFileSnapshot() == file, track.artworkData == memory,
                  track.title == query.title, track.artist == query.artist, track.album == query.album else {
                return await finish(id, result: .kept)
            }
            let changed = try await apply(id, candidate.imageData, file, memory)
            if changed { return await finish(id, result: .updated) }
            // A pause/close while waiting for the mutation owner is still
            // unfinished work, rather than a permanently skipped cover.
            try await context.checkpoint()
            guard !isClosed, !isPaused, !state.declined else { return .cancelled }
            return await finish(id, result: .kept)
        } catch is CancellationError { return .cancelled }
        catch {
            guard !isClosed, !isPaused, !state.declined, !Task.isCancelled else { return .cancelled }
            let attempts = (state.attempts[id] ?? 0) + 1
            state.attempts[id] = attempts
            if attempts >= 3 { state.results[id] = .failed }
            else { state.retryAfter[id] = Date().addingTimeInterval(attempts == 1 ? 60 : 300) }
            persist()
            await flush()
            Log.warning("[ArtworkRenovation] event=retry attempts=\(attempts) errorType=\(String(describing: type(of: error)))", category: .library)
            return .completed // Retry policy belongs to the durable backlog.
        }
    }

    private func finish(_ id: UUID, result: ArtworkRenovationState.Result) async -> BackgroundWorkOutcome {
        state.results[id] = result
        state.attempts[id] = nil
        state.retryAfter[id] = nil
        persist()
        await flush()
        return .completed
    }

    private func persist() {
        let snapshot = state
        let previous = persistenceTask
        persistenceTask = Task { [weak self, ledger] in
            await previous?.value
            do {
                try await ledger.save(snapshot)
                self?.lastError = nil
            }
            catch {
                guard let self else { return }
                self.lastError = "封面翻新进度暂时无法保存"
                self.setPaused(true)
                Log.error("[ArtworkRenovation] event=save-failed", category: .library)
            }
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        guard !isClosed, !state.declined,
              let next = state.retryAfter.filter({ state.results[$0.key] == nil }).values.filter({ $0 > Date() }).min() else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow) + 1))
            guard !Task.isCancelled, let self, !self.isClosed else { return }
            self.wake()
        }
    }
}
