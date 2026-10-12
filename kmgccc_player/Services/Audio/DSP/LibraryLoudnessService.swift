import AVFoundation
import CryptoKit
import Foundation
import Observation
import PlayerAutomationProtocol

/// Compact per-track summary kept for the whole library, so status counts and
/// idle planning never decode every cached record.
nonisolated struct LoudnessIndexEntry: Codable, Equatable, Sendable {
    var analyzerVersion: Int
    var usable: Bool
    var failed: Bool
    var analyzedAt: Date
}

private actor LoudnessDerivedCache {
    private let rootURL: URL
    private let fileManager = FileManager.default

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    private var indexURL: URL { rootURL.appendingPathComponent("index.json", isDirectory: false) }

    func loadRecent(limit: Int) throws -> [LoudnessTrackRecord] {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let mostRecentURLs = try urls.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "json", url.lastPathComponent != "index.json" else { return nil }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            return (url, values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(max(0, limit))
        let decoder = JSONDecoder()
        return Array(mostRecentURLs).reversed().compactMap { entry in
            guard let data = try? Data(contentsOf: entry.0),
                  let record = try? decoder.decode(LoudnessTrackRecord.self, from: data),
                  record.cacheRecordVersion == LoudnessTrackRecord.currentCacheRecordVersion else {
                return nil
            }
            return record
        }
    }

    func load(id: UUID) -> LoudnessTrackRecord? {
        let url = rootURL.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(LoudnessTrackRecord.self, from: data),
              record.cacheRecordVersion == LoudnessTrackRecord.currentCacheRecordVersion else { return nil }
        return record
    }

    func store(_ record: LoudnessTrackRecord) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
        let url = rootURL.appendingPathComponent("\(record.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url, options: [.atomic])
    }

    func loadIndex() -> [UUID: LoudnessIndexEntry]? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? JSONDecoder().decode([UUID: LoudnessIndexEntry].self, from: data)
    }

    /// Rebuilds the index from every record file when the index file is
    /// missing or unreadable.
    func rebuildIndex() -> [UUID: LoudnessIndexEntry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [:] }
        let decoder = JSONDecoder()
        var index: [UUID: LoudnessIndexEntry] = [:]
        for url in urls where url.pathExtension == "json" && url.lastPathComponent != "index.json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(LoudnessTrackRecord.self, from: data),
                  record.cacheRecordVersion == LoudnessTrackRecord.currentCacheRecordVersion else { continue }
            index[record.id] = LoudnessIndexEntry(
                analyzerVersion: record.analyzerVersion,
                usable: record.measurement?.isUsable == true,
                failed: record.measurement == nil,
                analyzedAt: record.analyzedAt
            )
        }
        return index
    }

    func storeIndex(_ index: [UUID: LoudnessIndexEntry]) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
        try JSONEncoder().encode(index).write(to: indexURL, options: [.atomic])
    }
}

private nonisolated struct LoudnessWorkerOutcome: Sendable {
    let record: LoudnessTrackRecord
    let failure: String?
}

nonisolated enum LoudnessAnalysisPhase: String, Codable, Equatable, Sendable {
    case readingTags
    case analyzing
    case saving

    nonisolated var title: String {
        switch self {
        case .readingTags: "读取标签"
        case .analyzing: "分析音频"
        case .saving: "保存结果"
        }
    }
}

/// Measurement status of one track as the listener can see it.
nonisolated enum LoudnessTrackMeasurementState: Equatable, Sendable {
    case unmeasured
    case waiting(BackgroundWorkPriority)
    case measuring(phase: LoudnessAnalysisPhase, fraction: Double?)
    case paused
    case measured
    case failed(String)
}

nonisolated struct LoudnessLibraryProgress: Equatable, Sendable {
    var measured: Int
    var failed: Int
    var remaining: Int
}

/// What playback applies to one track, and whether an album gain is still
/// being completed for it.
nonisolated struct LoudnessPlaybackPlan: Equatable, Sendable {
    var decision: LoudnessGainDecision
    /// Set when this track belongs to an album normalized as one unit.
    var albumKey: String?
    /// The album unifies but not every measurable member is measured yet;
    /// the track gain (or unity) is used meanwhile.
    var awaitingAlbum: Bool
    var trackMeasured: Bool

    nonisolated static let disabled = LoudnessPlaybackPlan(
        decision: .unity(source: LoudnessGainDecision.Source.disabled),
        albumKey: nil, awaitingAlbum: false, trackMeasured: false
    )
}

/// Library-scoped loudness measurement and derived-cache owner. Decoding is
/// admitted by the App-level background scheduler, never by the library's
/// write queue; playback only reads the in-memory snapshot.
@Observable
@MainActor
final class LibraryLoudnessService {
    private static let maximumInMemoryRecords = 512
    private nonisolated static let decodeChunkFrames: AVAudioFrameCount = 32_768
    /// A decode that ends before this share of the declared length is a
    /// failure rather than a short tail.
    private nonisolated static let minimumDecodedShare = 0.9

    @ObservationIgnored private let cache: LoudnessDerivedCache
    @ObservationIgnored private var records: [UUID: LoudnessTrackRecord] = [:]
    @ObservationIgnored private var recordLRU: [UUID] = []
    @ObservationIgnored private var pendingCacheLoads: Set<UUID> = []
    @ObservationIgnored private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored private var indexSaveTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var playbackAACGaplessTrimEnabled = false
    @ObservationIgnored private let groupID: String
    /// Tracks whose stored result is ignored on their next measurement.
    @ObservationIgnored private var forcedTrackIDs: Set<UUID> = []
    @ObservationIgnored private var backgroundActivityTask: Task<Void, Never>?

    private(set) var index: [UUID: LoudnessIndexEntry] = [:]
    private(set) var states: [UUID: LoudnessTrackMeasurementState] = [:]
    private(set) var hasLoadedSnapshot = false
    private(set) var isIdleScanActive = false
    /// The listener paused the library-wide measurement for this session.
    private(set) var isIdleScanPausedByListener = false
    /// Idle measurement ran recently; the sidebar shows a notice while true.
    private(set) var isBackgroundAnalysisVisible = false

    @ObservationIgnored weak var scheduler: BackgroundWorkScheduler?
    @ObservationIgnored var trackProvider: (@MainActor (UUID) -> Track?)?
    @ObservationIgnored var albumJudgementProvider: (@MainActor (Track) -> LoudnessAlbumJudgement?)?
    /// Called after a track's measurement result changes.
    @ObservationIgnored var onMeasurementFinished: (@MainActor (UUID) -> Void)?
    /// Called when an album's set of available measurements changes.
    @ObservationIgnored var onAlbumMeasurementsChanged: (@MainActor (String) -> Void)?

    init(libraryPaths: LibraryPaths, libraryID: UUID = UUID()) {
        cache = LoudnessDerivedCache(
            rootURL: libraryPaths.cacheRootURL.appendingPathComponent("Loudness", isDirectory: true)
        )
        groupID = "loudness:\(libraryID.uuidString)"
    }

    func loadSnapshot() async {
        guard !isClosed, !hasLoadedSnapshot else { return }
        if let loaded = try? await cache.loadRecent(limit: Self.maximumInMemoryRecords) {
            guard !isClosed else { return }
            for record in loaded { insert(record) }
        }
        var loadedIndex = await cache.loadIndex()
        if loadedIndex == nil {
            let rebuilt = await cache.rebuildIndex()
            loadedIndex = rebuilt
            try? await cache.storeIndex(rebuilt)
        }
        guard !isClosed else { return }
        index.merge(loadedIndex ?? [:]) { current, _ in current }
        hasLoadedSnapshot = true
    }

    func updatePlaybackTrimPolicy(enabled: Bool) {
        playbackAACGaplessTrimEnabled = enabled
    }

    // MARK: - Status

    func measurementState(for trackID: UUID) -> LoudnessTrackMeasurementState {
        if let state = states[trackID] { return state }
        if let entry = index[trackID], entry.analyzerVersion == LoudnessMeasurement.currentAnalyzerVersion {
            return entry.failed || !entry.usable ? .failed("无法测量这首歌曲") : .measured
        }
        if let priority = scheduler?.priority(of: workKey(trackID)) { return .waiting(priority) }
        return .unmeasured
    }

    func record(for trackID: UUID) -> LoudnessTrackRecord? { records[trackID] }

    func libraryProgress(trackIDs: [UUID]) -> LoudnessLibraryProgress {
        var measured = 0
        var failed = 0
        for id in trackIDs {
            guard let entry = index[id], entry.analyzerVersion == LoudnessMeasurement.currentAnalyzerVersion else { continue }
            if entry.usable { measured += 1 } else { failed += 1 }
        }
        return LoudnessLibraryProgress(measured: measured, failed: failed,
                                       remaining: max(0, trackIDs.count - measured - failed))
    }

    /// Library tracks whose current measurement failed, in library order.
    func failedTrackIDs(in trackIDs: [UUID]) -> [UUID] {
        trackIDs.filter { id in
            if case .failed = measurementState(for: id) { return true }
            return false
        }
    }

    /// Why a measurement failed, when this session saw the failure.
    func failureMessage(for trackID: UUID) -> String? {
        if case .failed(let message) = measurementState(for: trackID) { return message }
        return nil
    }

    func recordsSnapshot(trackIDs: [UUID]) -> [UUID: LoudnessTrackRecord] {
        Dictionary(uniqueKeysWithValues: Set(trackIDs).compactMap { id in records[id].map { (id, $0) } })
    }

    func loadRecordsSnapshot(trackIDs: [UUID]) async -> [UUID: LoudnessTrackRecord] {
        guard !isClosed else { return [:] }
        var seen = Set<UUID>()
        var result: [UUID: LoudnessTrackRecord] = [:]
        for id in trackIDs where seen.insert(id).inserted {
            guard !isClosed else { break }
            if let record = records[id] {
                touch(id)
                result[id] = record
            } else if let record = await cache.load(id: id) {
                guard !isClosed else { break }
                insert(record)
                if let current = records[id] { result[id] = current }
            }
        }
        return result
    }

    // MARK: - Playback

    /// The gain playback should use now for `track`. Missing measurements are
    /// queued as upcoming work; nothing here decodes audio.
    func playbackPlan(
        track: Track,
        fileURL: URL?,
        configuration: AudioLoudnessConfiguration
    ) -> LoudnessPlaybackPlan {
        guard configuration.enabled, !isClosed else { return .disabled }
        let trackRecord = currentRecord(for: track, fileURL: fileURL)
        let trackMeasured = trackRecord?.measurement?.isUsable == true
        if trackRecord == nil { requestMeasurement(trackIDs: [track.id], priority: .upcoming) }
        let trackDecision = LoudnessGainSelector.trackGain(
            configuration: configuration,
            measurement: trackRecord?.measurement
        )

        guard let judgement = albumJudgementProvider?(track), judgement.unifies,
              judgement.memberIDs.count > 1 else {
            return LoudnessPlaybackPlan(decision: trackDecision, albumKey: nil,
                                        awaitingAlbum: false, trackMeasured: trackMeasured)
        }
        let status = albumMeasurementStatus(memberIDs: judgement.memberIDs, playingTrackID: track.id,
                                            playingRecord: trackRecord)
        if !status.missing.isEmpty {
            requestMeasurement(trackIDs: status.missing, priority: .upcoming)
        }
        if status.missing.isEmpty, !status.loading,
           let albumDecision = LoudnessGainSelector.albumGain(configuration: configuration,
                                                              measurements: status.measurements) {
            return LoudnessPlaybackPlan(decision: albumDecision, albumKey: judgement.albumKey,
                                        awaitingAlbum: false, trackMeasured: trackMeasured)
        }
        return LoudnessPlaybackPlan(decision: trackDecision, albumKey: judgement.albumKey,
                                    awaitingAlbum: true, trackMeasured: trackMeasured)
    }

    private func albumMeasurementStatus(
        memberIDs: [UUID],
        playingTrackID: UUID,
        playingRecord: LoudnessTrackRecord?
    ) -> (measurements: [LoudnessMeasurement], missing: [UUID], loading: Bool) {
        var measurements: [LoudnessMeasurement] = []
        var missing: [UUID] = []
        var loading = false
        for id in memberIDs {
            let record = id == playingTrackID ? playingRecord : records[id].flatMap { isCurrentVersion($0) ? $0 : nil }
            if let record {
                touch(id)
                // A member that could not be decoded is left out of the album.
                if let measurement = record.measurement, measurement.isUsable { measurements.append(measurement) }
                continue
            }
            if case .failed = states[id] { continue }
            if let entry = index[id], entry.analyzerVersion == LoudnessMeasurement.currentAnalyzerVersion {
                if entry.usable {
                    loading = true
                    requestCacheRecordLoad(trackID: id)
                }
                continue
            }
            missing.append(id)
        }
        return (measurements, missing, loading)
    }

    // MARK: - Measurement requests

    /// Queues measurement of tracks that have no current result. A request
    /// for a track already queued only raises its priority.
    func requestMeasurement(trackIDs: [UUID], priority: BackgroundWorkPriority) {
        guard !isClosed, let scheduler else { return }
        for id in trackIDs {
            if case .measuring = states[id] { continue }
            if priority != .userRequested, case .failed = states[id] { continue }
            if priority == .idleBatch, let entry = index[id],
               entry.analyzerVersion == LoudnessMeasurement.currentAnalyzerVersion { continue }
            scheduler.submit(key: workKey(id), group: groupID, priority: priority) { [weak self] context in
                await self?.runMeasurement(trackID: id, context: context)
            }
            if case .measured = measurementState(for: id), priority != .userRequested { continue }
            states[id] = .waiting(scheduler.priority(of: workKey(id)) ?? priority)
        }
    }

    /// Queues every library track without a current measurement as idle
    /// work, in the given order (upcoming, often played, then the rest).
    func startIdleLibraryScan(orderedTrackIDs: [UUID]) {
        guard !isClosed, hasLoadedSnapshot, !isIdleScanPausedByListener else { return }
        isIdleScanActive = true
        requestMeasurement(trackIDs: orderedTrackIDs, priority: .idleBatch)
    }

    /// Withdraws idle work when volume normalization is switched off. A
    /// listener's explicit request keeps running.
    func stopIdleLibraryScan(clearingPause: Bool = false) {
        if clearingPause { isIdleScanPausedByListener = false }
        guard let scheduler else { return }
        isIdleScanActive = false
        for (id, state) in states {
            guard case .waiting(let priority) = state, priority == .idleBatch else { continue }
            scheduler.cancel(key: workKey(id))
            states[id] = nil
        }
        // A running idle measurement stops at its next checkpoint.
        for (id, state) in states {
            guard case .measuring = state, scheduler.priority(of: workKey(id)) == .idleBatch else { continue }
            scheduler.cancel(key: workKey(id))
            states[id] = nil
            resumeWaiters(id)
        }
        setBackgroundAnalysisVisible(false)
    }

    /// The listener's pause from the sidebar notice. Playback still measures
    /// the songs it needs; the library-wide pass waits for `resume`.
    func pauseIdleLibraryScan() {
        isIdleScanPausedByListener = true
        stopIdleLibraryScan()
    }

    func resumeIdleLibraryScan(orderedTrackIDs: [UUID]) {
        isIdleScanPausedByListener = false
        startIdleLibraryScan(orderedTrackIDs: orderedTrackIDs)
    }

    /// Explicit Job request: measures the targets at the listener's priority
    /// and reports real progress until each one finishes. `force` measures
    /// again even when a current result is stored.
    func scan(
        trackIDs: [UUID],
        force: Bool = false,
        reporter: LibraryAutomationJobReporter
    ) async {
        guard !isClosed else { return }
        var seen = Set<UUID>()
        let targets = trackIDs.filter { seen.insert($0).inserted }
        guard !targets.isEmpty else { return }
        for id in targets {
            if case .failed = states[id] { states[id] = nil }
            index[id] = nil
        }
        if force { forcedTrackIDs.formUnion(targets) }
        requestMeasurement(trackIDs: targets, priority: .userRequested)
        reporter.recordProgress(completedCount: 0, totalCount: targets.count, phase: "Analyzing")

        var completed = 0
        var available = 0
        await withTaskCancellationHandler {
            for id in targets {
                if Task.isCancelled { break }
                await waitForMeasurement(trackID: id)
                completed += 1
                switch states[id] ?? measurementState(for: id) {
                case .measured: available += 1
                case .failed(let message): reporter.recordFailure(message, itemID: id)
                default: reporter.recordFailure("测量未完成。", itemID: id)
                }
                reporter.recordProgress(completedCount: completed, totalCount: targets.count, phase: "Analyzing")
                reporter.recordCheckpoint("Analyzed \(completed) item(s)")
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRequested(targets) }
        }
        reporter.recordResult(.object([
            "operationType": .string(AutomationMethod.audioLoudnessAnalyze),
            "trackIDs": .array(targets.map { .string($0.uuidString) }),
            "processedCount": .number(Double(completed)),
            "availableMeasurementCount": .number(Double(available)),
            "unavailableMeasurementCount": .number(Double(completed - available)),
            "currentPlaybackUnchanged": .boolean(true),
        ]))
        reporter.recordProgress(completedCount: completed, totalCount: max(targets.count, 1), phase: "Finished")
    }

    func cancel() {
        isClosed = true
        setBackgroundAnalysisVisible(false)
        scheduler?.cancel(group: groupID)
        onMeasurementFinished = nil
        onAlbumMeasurementsChanged = nil
        pendingCacheLoads.removeAll(keepingCapacity: false)
        for continuations in waiters.values { continuations.forEach { $0.resume() } }
        waiters.removeAll()
        if let indexSaveTask {
            indexSaveTask.cancel()
            let snapshot = index
            let cache = cache
            Task { try? await cache.storeIndex(snapshot) }
        }
    }

    private func cancelRequested(_ trackIDs: [UUID]) {
        for id in trackIDs {
            scheduler?.cancel(key: workKey(id))
            if case .measuring = states[id] { states[id] = nil }
            if case .waiting = states[id] { states[id] = nil }
            resumeWaiters(id)
        }
    }

    private func waitForMeasurement(trackID: UUID) async {
        switch states[trackID] {
        case .waiting, .measuring, .paused:
            await withCheckedContinuation { continuation in
                waiters[trackID, default: []].append(continuation)
            }
        default:
            return
        }
    }

    private func resumeWaiters(_ trackID: UUID) {
        waiters.removeValue(forKey: trackID)?.forEach { $0.resume() }
    }

    private func workKey(_ trackID: UUID) -> String {
        "\(groupID):\(trackID.uuidString):v\(LoudnessMeasurement.currentAnalyzerVersion)"
    }

    // MARK: - Worker

    private func runMeasurement(trackID: UUID, context: BackgroundWorkContext) async {
        guard !isClosed else { return }
        let isIdleWork = scheduler?.priority(of: workKey(trackID)) == .idleBatch
        if isIdleWork { noteBackgroundAnalysisActivity() }
        defer {
            resumeWaiters(trackID)
            if isIdleWork { noteBackgroundAnalysisActivity() }
        }
        guard let track = trackProvider?(trackID) else {
            finishFailure(trackID, message: "这首歌曲已不在资料库中。")
            return
        }
        states[trackID] = .measuring(phase: .readingTags, fraction: nil)
        let resolution = track.resolveFileURL()
        defer { resolution.lease.release() }
        guard let fileURL = resolution.url,
              let identity = try? Self.fileIdentity(for: fileURL) else {
            finishFailure(trackID, message: "无法打开这首歌曲的音频文件。")
            return
        }
        let trim = playbackAACGaplessTrimEnabled
        let forced = forcedTrackIDs.remove(trackID) != nil
        var cached = forced ? nil : records[trackID]
        if cached == nil, !forced { cached = await cache.load(id: trackID) }
        if let cached, Self.isCurrent(cached, for: identity, playbackAACGaplessTrimEnabled: trim) {
            insert(cached)
            finishSuccess(cached, store: false)
            return
        }

        let progress: @Sendable (LoudnessAnalysisPhase, Double?) -> Void = { [weak self] phase, fraction in
            Task { @MainActor [weak self] in
                guard let self, case .measuring = self.states[trackID] else { return }
                self.states[trackID] = .measuring(phase: phase, fraction: fraction)
            }
        }
        do {
            let outcome = try await Task.detached(priority: .utility) {
                try await Self.analyze(
                    trackID: trackID, url: fileURL, identity: identity,
                    playbackAACGaplessTrimEnabled: trim, context: context, progress: progress
                )
            }.value
            guard !isClosed else { return }
            guard (try? Self.fileIdentity(for: fileURL)) == identity, trim == playbackAACGaplessTrimEnabled else {
                states[trackID] = nil
                return
            }
            states[trackID] = .measuring(phase: .saving, fraction: 1)
            insert(outcome.record)
            if let failure = outcome.failure {
                try? await cache.store(outcome.record)
                finishFailure(trackID, message: failure, record: outcome.record)
            } else {
                finishSuccess(outcome.record, store: true)
            }
        } catch is CancellationError {
            if !isClosed { states[trackID] = nil }
        } catch {
            finishFailure(trackID, message: "无法测量：\(error.localizedDescription)")
        }
    }

    private func finishSuccess(_ record: LoudnessTrackRecord, store: Bool) {
        let id = record.id
        if store {
            let cache = cache
            Task { try? await cache.store(record) }
        }
        index[id] = LoudnessIndexEntry(
            analyzerVersion: record.analyzerVersion,
            usable: record.measurement?.isUsable == true,
            failed: record.measurement == nil,
            analyzedAt: record.analyzedAt
        )
        states[id] = record.measurement?.isUsable == true ? .measured : .failed("这首歌曲没有可测量的声音。")
        scheduleIndexSave()
        notifyChanged(id)
    }

    private func finishFailure(_ trackID: UUID, message: String, record: LoudnessTrackRecord? = nil) {
        states[trackID] = .failed(message)
        index[trackID] = LoudnessIndexEntry(
            analyzerVersion: LoudnessMeasurement.currentAnalyzerVersion,
            usable: false, failed: true, analyzedAt: record?.analyzedAt ?? Date()
        )
        scheduleIndexSave()
        notifyChanged(trackID)
    }

    /// Keeps the sidebar notice up while idle measurement keeps finding work,
    /// and through short pauses (for example while the listener reaches for
    /// the pause button); it goes once the pass ends or stays quiet.
    private func noteBackgroundAnalysisActivity() {
        let hasPendingIdleWork = states.values.contains { state in
            switch state {
            case .waiting(let priority): priority == .idleBatch
            case .measuring: true
            default: false
            }
        }
        guard isIdleScanActive, hasPendingIdleWork else {
            setBackgroundAnalysisVisible(false)
            return
        }
        setBackgroundAnalysisVisible(true)
        backgroundActivityTask?.cancel()
        backgroundActivityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            self?.isBackgroundAnalysisVisible = false
        }
    }

    private func setBackgroundAnalysisVisible(_ visible: Bool) {
        if !visible {
            backgroundActivityTask?.cancel()
            backgroundActivityTask = nil
        }
        if isBackgroundAnalysisVisible != visible { isBackgroundAnalysisVisible = visible }
    }

    private func notifyChanged(_ trackID: UUID) {
        onMeasurementFinished?(trackID)
        if let albumKey = trackProvider?(trackID)?.albumGroupKey, !albumKey.isEmpty {
            onAlbumMeasurementsChanged?(albumKey)
        }
    }

    private func scheduleIndexSave() {
        guard indexSaveTask == nil else { return }
        indexSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            self.indexSaveTask = nil
            let snapshot = self.index
            try? await self.cache.storeIndex(snapshot)
        }
    }

    // MARK: - Records

    private func currentRecord(for track: Track, fileURL: URL?) -> LoudnessTrackRecord? {
        guard let record = records[track.id] else {
            if index[track.id] != nil { requestCacheRecordLoad(trackID: track.id) }
            return nil
        }
        if let fileURL {
            guard let identity = try? Self.fileIdentity(for: fileURL),
                  Self.isCurrent(record, for: identity, playbackAACGaplessTrimEnabled: playbackAACGaplessTrimEnabled)
            else { return nil }
        } else if !isCurrentVersion(record) {
            return nil
        }
        touch(track.id)
        return record
    }

    private func isCurrentVersion(_ record: LoudnessTrackRecord) -> Bool {
        record.cacheRecordVersion == LoudnessTrackRecord.currentCacheRecordVersion
            && record.playbackAACGaplessTrimEnabled == playbackAACGaplessTrimEnabled
            && (record.measurement.map {
                $0.analyzerVersion == LoudnessMeasurement.currentAnalyzerVersion
                    && $0.trimPolicyVersion == LoudnessMeasurement.currentTrimPolicyVersion
            } ?? false)
    }

    private func insert(_ record: LoudnessTrackRecord) {
        if let current = records[record.id], current.analyzedAt > record.analyzedAt {
            touch(record.id)
            return
        }
        records[record.id] = record
        touch(record.id)
        while recordLRU.count > Self.maximumInMemoryRecords {
            let evicted = recordLRU.removeFirst()
            records.removeValue(forKey: evicted)
        }
    }

    private func touch(_ id: UUID) {
        recordLRU.removeAll { $0 == id }
        recordLRU.append(id)
    }

    private func requestCacheRecordLoad(trackID: UUID) {
        guard !isClosed, pendingCacheLoads.insert(trackID).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let loaded = await self.cache.load(id: trackID)
            self.pendingCacheLoads.remove(trackID)
            guard !self.isClosed, let loaded else { return }
            self.insert(loaded)
            self.notifyChanged(trackID)
        }
    }

    private static func isCurrent(
        _ record: LoudnessTrackRecord,
        for identity: LoudnessFileIdentity,
        playbackAACGaplessTrimEnabled: Bool
    ) -> Bool {
        guard record.cacheRecordVersion == LoudnessTrackRecord.currentCacheRecordVersion,
              record.metadataParserVersion == LoudnessMetadata.currentParserVersion,
              record.playbackAACGaplessTrimEnabled == playbackAACGaplessTrimEnabled,
              record.fileIdentity == identity else { return false }
        // A failure carries no analyzer version; it is decoded again when
        // requested instead of being reused across analyzer changes.
        guard let measurement = record.measurement else { return false }
        return measurement.analyzerVersion == LoudnessMeasurement.currentAnalyzerVersion
            && measurement.decoderRuleVersion == LoudnessMeasurement.currentDecoderRuleVersion
            && measurement.trimPolicyVersion == LoudnessMeasurement.currentTrimPolicyVersion
            && measurement.analysisFrameRange == "renderer-decoded-range-v2"
            && measurement.playbackAACGaplessTrimEnabled == playbackAACGaplessTrimEnabled
    }

    private nonisolated static func fileIdentity(for url: URL) throws -> LoudnessFileIdentity {
        let standardizedURL = url.standardizedFileURL
        let values = try standardizedURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
        ])
        guard let fileSize = values.fileSize,
              let modificationDate = values.contentModificationDate else {
            throw CocoaError(.fileReadUnknown)
        }
        let time = modificationDate.timeIntervalSince1970 * 1_000_000_000
        guard time.isFinite, time >= Double(Int64.min), time <= Double(Int64.max) else {
            throw CocoaError(.fileReadUnknown)
        }
        let digest = SHA256.hash(data: Data(standardizedURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return LoudnessFileIdentity(
            pathDigest: digest,
            resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
            fileSize: Int64(fileSize),
            modificationTimeNanoseconds: Int64(time.rounded())
        )
    }

    /// One sequential decode of the playback frame range. Pause and cancel
    /// are honored between decode chunks; progress is reported at most four
    /// times a second.
    private nonisolated static func analyze(
        trackID: UUID,
        url: URL,
        identity: LoudnessFileIdentity,
        playbackAACGaplessTrimEnabled: Bool,
        context: BackgroundWorkContext,
        progress: @escaping @Sendable (LoudnessAnalysisPhase, Double?) -> Void
    ) async throws -> LoudnessWorkerOutcome {
        try await context.checkpoint()
        progress(.readingTags, nil)
        var metadata = await readMetadata(from: url)
        try await context.checkpoint()

        var measurement: LoudnessMeasurement?
        var failure: String?
        do {
            let audioFile = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let dspFormat = Self.dspFormat(for: audioFile)
            guard dspFormat.channelCount > 0, dspFormat.channelCount <= 64 else {
                throw LoudnessScanError.unsupportedChannelCount
            }
            let range = AACDecodedFrameRange.resolve(metadata: AACGaplessMetadata.read(url: url),
                decodedFrames: audioFile.length, enabled: playbackAACGaplessTrimEnabled)
            audioFile.framePosition = range.startingFrame
            let endFrame = range.startingFrame + range.frameCount
            let analyzer = LoudnessAnalyzer(format: dspFormat)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: decodeChunkFrames
            ) else {
                throw LoudnessScanError.bufferAllocationFailed
            }

            progress(.analyzing, 0)
            var lastReport = ProcessInfo.processInfo.systemUptime
            var decoderStoppedEarly = false
            while audioFile.framePosition < endFrame {
                try await context.checkpoint()
                let remaining = endFrame - audioFile.framePosition
                let requestedFrames = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
                guard requestedFrames > 0 else { break }
                do {
                    try audioFile.read(into: buffer, frameCount: requestedFrames)
                } catch {
                    // A damaged tail ends decoding the same way it ends playback.
                    decoderStoppedEarly = true
                    break
                }
                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0 else {
                    decoderStoppedEarly = true
                    break
                }
                guard let channelData = buffer.floatChannelData else {
                    throw LoudnessScanError.floatPCMUnavailable
                }
                analyzer.append(channelData: UnsafePointer(channelData), frameCount: frameCount)
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastReport >= 0.25, range.frameCount > 0 {
                    lastReport = now
                    progress(.analyzing, Double(analyzer.receivedFrames) / Double(range.frameCount))
                }
            }
            var result = analyzer.finish(playbackAACGaplessTrimEnabled: playbackAACGaplessTrimEnabled)
            let analyzedFrames = result.analyzedFrameCount
            // The declared length is an estimate for VBR MP3 and can overstate
            // files with a damaged tail; decoding usually ends a fraction of a
            // second early. What decodes is what plays, so it is measured,
            // unless most of the file is missing.
            if analyzedFrames < range.frameCount {
                guard Double(analyzedFrames) >= Double(range.frameCount) * Self.minimumDecodedShare else {
                    throw LoudnessScanError.incompleteDecodedRange
                }
                result.diagnostics.append(DSPDiagnostic(
                    code: "audio.loudnessDecodedShort",
                    message: "Decoding ended \(range.frameCount - analyzedFrames) frame(s) before the declared length"
                        + (decoderStoppedEarly ? " at end of stream." : "."),
                    fieldPath: "loudness.analysisFrameRange"
                ))
            }
            result.validStartFrame = range.startingFrame
            result.validEndFrame = range.startingFrame + analyzedFrames
            result.analysisFrameRange = "renderer-decoded-range-v2"
            if range.reason != "fullFile" && !range.isTrimmed {
                result.diagnostics.append(DSPDiagnostic(code: "audio.loudnessTrimFallback",
                    message: "AAC crop metadata did not match the decoded range; playback and analysis use the complete decoded file.",
                    fieldPath: "loudness.analysisFrameRange"))
            }
            measurement = result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failure = "音频无法解码，未能测量响度。"
            Log.warning(
                "[Loudness] decode failed track=\(trackID) file=\(url.lastPathComponent) error=\(error.localizedDescription)",
                category: .audio
            )
            metadata.diagnostics.append(DSPDiagnostic(
                code: "audio.loudnessDecodeFailed",
                message: "Decoded PCM was unavailable for loudness measurement: \(error.localizedDescription)",
                fieldPath: "loudness.measurement",
                retryable: true
            ))
        }

        return LoudnessWorkerOutcome(
            record: LoudnessTrackRecord(
                id: trackID,
                cacheRecordVersion: LoudnessTrackRecord.currentCacheRecordVersion,
                metadataParserVersion: LoudnessMetadata.currentParserVersion,
                playbackAACGaplessTrimEnabled: playbackAACGaplessTrimEnabled,
                fileIdentity: identity,
                measurement: measurement,
                metadata: metadata,
                analyzedAt: Date()
            ),
            failure: failure
        )
    }

    private nonisolated static func readMetadata(from url: URL) async -> LoudnessMetadata {
        let asset = AVURLAsset(url: url)
        var tags: [LoudnessMetadataTag] = []
        var readFailed = false
        do {
            let formats = try await asset.load(.availableMetadataFormats)
            for format in formats {
                try Task.checkCancellation()
                let items = try await asset.loadMetadata(for: format)
                for item in items {
                    guard let key = item.identifier?.rawValue
                            ?? (item.key as? String)
                            ?? item.commonKey?.rawValue else { continue }
                    let stringValue = try? await item.load(.stringValue)
                    let value: String?
                    if let stringValue {
                        value = stringValue
                    } else {
                        value = (try? await item.load(.numberValue))?.stringValue
                    }
                    guard let value else { continue }
                    tags.append(LoudnessMetadataTag(key: key, value: value))
                }
            }
        } catch is CancellationError {
            return .empty
        } catch {
            readFailed = true
        }
        let metadata = LoudnessMetadataParser.parse(tags: tags, containerHint: containerHint(for: url))
        guard readFailed else { return metadata }
        var result = metadata
        result.diagnostics.append(DSPDiagnostic(
            code: "audio.loudnessMetadataReadFailed",
            message: "Container normalization metadata could not be read; the PCM scan remains authoritative.",
            fieldPath: "loudness.metadata",
            retryable: true
        ))
        return result
    }

    private nonisolated static func containerHint(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "opus": return "opus"
        case "mp3", "flac", "wav", "wave", "aif", "aiff", "m4a", "mp4", "caf":
            return url.pathExtension.lowercased()
        default:
            return "unknown"
        }
    }

    private nonisolated static func dspFormat(for audioFile: AVAudioFile) -> DSPAudioFormat {
        let processingFormat = audioFile.processingFormat
        let processingDSPFormat = CMSampleBufferFactory.dspAudioFormat(from: processingFormat)
        guard processingFormat.channelLayout == nil,
              audioFile.fileFormat.channelLayout != nil else { return processingDSPFormat }
        let fileDSPFormat = CMSampleBufferFactory.dspAudioFormat(from: audioFile.fileFormat)
        guard fileDSPFormat.channelCount == Int(processingFormat.channelCount),
              let sourceLayout = fileDSPFormat.rawLayoutData else { return processingDSPFormat }
        return DSPAudioFormat(
            sampleRate: processingFormat.sampleRate,
            channelCount: Int(processingFormat.channelCount),
            rawLayoutData: sourceLayout,
            channelLabels: fileDSPFormat.channelLabels,
            layoutIsKnown: fileDSPFormat.layoutIsKnown
        )
    }
}

private nonisolated enum LoudnessScanError: LocalizedError {
    case incompleteDecodedRange
    case unsupportedChannelCount
    case bufferAllocationFailed
    case floatPCMUnavailable

    var errorDescription: String? {
        switch self {
        case .incompleteDecodedRange:
            "The decoder ended before the complete playback frame range was measured."
        case .unsupportedChannelCount:
            "The decoded source channel count is outside the supported bounded range."
        case .bufferAllocationFailed:
            "A bounded PCM analysis buffer could not be allocated."
        case .floatPCMUnavailable:
            "The decoder did not provide planar Float32 PCM."
        }
    }
}
