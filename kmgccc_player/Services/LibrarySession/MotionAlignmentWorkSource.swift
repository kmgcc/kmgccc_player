import Foundation

private actor MotionAlignmentLedger {
    nonisolated struct Entry: Codable, Sendable {
        var fingerprint: String
        var matched: Bool
    }
    nonisolated struct State: Codable, Sendable {
        var version = 1
        var entries: [String: Entry] = [:]
    }
    private let url: URL
    init(url: URL) { self.url = url }
    func load() -> State {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data), state.version == 1 else { return State() }
        return state
    }
    func save(_ state: State) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
}

/// Idle, per-song backlog. A negative match is remembered as a completed
/// inspection; replacing the song or video makes it eligible again.
@MainActor
final class MotionAlignmentWorkSource: BackgroundWorkSource {
    let sourceID: String
    let owner: BackgroundWorkOwner
    nonisolated var domain: BackgroundWorkDomain { .motionAlignment }
    nonisolated var resources: BackgroundWorkResources { [.compute, .disk] }
    private let alignment: MotionAudioAlignmentCoordinator
    private let analyze: @MainActor (Track, URL, BackgroundWorkContext) async -> MotionAudioAlignmentCoordinator.Result
    private let tracks: @MainActor () -> [Track]
    private let revision: @MainActor () -> Int
    private let wake: @MainActor () -> Void
    private let ledger: MotionAlignmentLedger
    private var state = MotionAlignmentLedger.State()
    private var ready = false
    private var closed = false
    private var cachedRevision = -1
    private var candidates: [Track] = []
    private var fingerprints: [UUID: String] = [:]
    private var failures = Set<UUID>()
    private var runningID: UUID?
    private var runningContext: BackgroundWorkContext?
    private var loadTask: Task<Void, Never>?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(libraryID: UUID, owner: BackgroundWorkOwner, rootURL: URL,
         alignment: MotionAudioAlignmentCoordinator, tracks: @escaping @MainActor () -> [Track],
         revision: @escaping @MainActor () -> Int, wake: @escaping @MainActor () -> Void,
         analyze: (@MainActor (Track, URL, BackgroundWorkContext) async -> MotionAudioAlignmentCoordinator.Result)? = nil) {
        sourceID = "motion-alignment:\(libraryID)"
        self.owner = owner
        self.alignment = alignment
        self.analyze = analyze ?? { track, video, context in
            await alignment.analyze(track: track, video: video, context: context)
        }
        self.tracks = tracks
        self.revision = revision
        self.wake = wake
        ledger = MotionAlignmentLedger(url: rootURL.appendingPathComponent("motion-alignment-v1.json"))
        loadTask = Task { [weak self, ledger] in
            let loaded = await ledger.load()
            guard let self, !self.closed else { return }
            self.state = loaded
            self.ready = true
            self.wake()
        }
    }

    func prepare() async { await loadTask?.value }

    var progress: BackgroundWorkProgress {
        refreshCandidates()
        let completed = candidates.filter { isCompleted($0) }.count
        return BackgroundWorkProgress(completed: completed, failed: failures.count,
                                      remaining: max(0, candidates.count - completed))
    }

    func invalidate(trackIDs: [UUID]? = nil) {
        cachedRevision = -1
        if let trackIDs { for id in trackIDs { alignment.invalidate(trackID: id); failures.remove(id) } }
        wake()
    }

    func close() async {
        closed = true
        loadTask?.cancel()
        runningContext?.cancel()
        if runningContext != nil {
            await withCheckedContinuation { closeWaiters.append($0) }
        }
    }

    func hasWork(priority: BackgroundWorkPriority, excluding: Set<String>) -> Bool {
        candidate(priority: priority, excluding: excluding) != nil
    }

    func nextUnit(priority: BackgroundWorkPriority, excluding: Set<String>) -> BackgroundWorkUnit? {
        guard let track = candidate(priority: priority, excluding: excluding),
              let video = track.storedMotionArtworkResource?.url,
              let fingerprint = fingerprints[track.id] else { return nil }
        let id = track.id
        runningID = id
        return BackgroundWorkUnit(id: id.uuidString, priority: priority) { [weak self] context in
            guard let self else { return .cancelled }
            return await self.run(trackID: id, video: video, fingerprint: fingerprint, context: context)
        }
    }

    func unitDidEnd(unitID: String, outcome: BackgroundWorkOutcome) {
        runningID = nil
        runningContext = nil
    }

    private func run(trackID: UUID, video: URL, fingerprint: String, context: BackgroundWorkContext) async -> BackgroundWorkOutcome {
        guard !closed, let track = tracks().first(where: { $0.id == trackID }),
              track.storedMotionArtworkResource?.url == video else { return .cancelled }
        runningContext = context
        defer {
            runningContext = nil
            let waiters = closeWaiters
            closeWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let result = await analyze(track, video, context)
        guard !closed, !context.isCancelled, !Task.isCancelled else { return .cancelled }
        cachedRevision = -1
        refreshCandidates()
        guard fingerprints[trackID] == fingerprint else { return .cancelled }
        switch result {
        case .cancelled: return .cancelled
        case .failed:
            failures.insert(trackID)
            return .failed("音频分析失败")
        case .matched, .unmatched:
            var next = state
            next.entries[trackID.uuidString] = MotionAlignmentLedger.Entry(fingerprint: fingerprint, matched: {
                if case .matched = result { return true }; return false
            }())
            do { try await ledger.save(next) }
            catch { failures.insert(trackID); return .failed("无法保存对齐结果") }
            guard !closed, !context.isCancelled, !Task.isCancelled else { return .cancelled }
            state = next
            failures.remove(trackID)
            return .completed
        }
    }

    private func candidate(priority: BackgroundWorkPriority, excluding: Set<String>) -> Track? {
        guard ready, !closed, priority == .idleBatch, runningID == nil else { return nil }
        refreshCandidates()
        return candidates.first { !excluding.contains($0.id.uuidString) && !isCompleted($0) }
    }

    private func isCompleted(_ track: Track) -> Bool {
        guard let entry = state.entries[track.id.uuidString], entry.fingerprint == fingerprints[track.id] else { return false }
        guard entry.matched else { return true }
        let path = URL(fileURLWithPath: track.libraryRootSnapshot, isDirectory: true)
            .appendingPathComponent("Enrichment/MotionAlignment/\(track.id.uuidString).json")
        return FileManager.default.fileExists(atPath: path.path)
    }

    private func refreshCandidates() {
        let current = revision()
        guard cachedRevision != current else { return }
        cachedRevision = current
        candidates = tracks().filter { track in
            guard let resource = track.storedMotionArtworkResource else { return false }
            return MotionAudioAligner.isMusicVideo(songDuration: track.duration, videoDuration: resource.duration)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        fingerprints = Dictionary(uniqueKeysWithValues: candidates.compactMap { track in
            guard let resource = track.storedMotionArtworkResource else { return nil }
            guard let locator = try? encoder.encode(track.mediaLocator) else { return nil }
            let attributes = try? FileManager.default.attributesOfItem(atPath: resource.url.path)
            let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let identity = "\(track.libraryRootSnapshot)|\(track.id)|\(track.duration)|\(locator.base64EncodedString())|\(resource.url.path)|\(resource.duration)|\(size)|\(modified)"
            return (track.id, MusicEnrichmentStore.digest(identity))
        })
        failures.formIntersection(Set(candidates.map(\.id)))
    }
}
