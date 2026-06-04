//
//  TelemetryService.swift
//  myPlayer2
//
//  kmgccc_player - Consent-based anonymous usage telemetry.
//

import AppKit
import Foundation

enum TelemetryPlaybackMode: String, Codable {
    case local
    case appleMusic = "apple_music"
    case external

    init(source: PlaybackSource) {
        switch source {
        case .local:
            self = .local
        case .appleMusic:
            self = .appleMusic
        case .systemNowPlaying:
            self = .external
        }
    }
}

enum TelemetrySessionEndReason: String, Codable {
    case appTerminated = "app_terminated"
    case recoveredAfterUngracefulExit = "recovered_after_ungraceful_exit"
    case other
}

private enum TelemetryTimelineKind: String, Codable {
    case foreground
    case mode
    case playback
}

private enum TelemetryTimelineValue: String, Codable {
    case active
    case inactive
    case local
    case appleMusic = "apple_music"
    case external
    case playing
    case notPlaying = "not_playing"

    init(foregroundActive: Bool) {
        self = foregroundActive ? .active : .inactive
    }

    init(mode: TelemetryPlaybackMode) {
        switch mode {
        case .local:
            self = .local
        case .appleMusic:
            self = .appleMusic
        case .external:
            self = .external
        }
    }

    init(isPlaying: Bool) {
        self = isPlaying ? .playing : .notPlaying
    }
}

private struct TelemetryTimelineSegment: Codable {
    let kind: TelemetryTimelineKind
    let value: TelemetryTimelineValue
    let startOffsetSeconds: Int
    let endOffsetSeconds: Int

    enum CodingKeys: String, CodingKey {
        case kind
        case value
        case startOffsetSeconds = "start_offset_seconds"
        case endOffsetSeconds = "end_offset_seconds"
    }
}

private struct TelemetryOpenTimelineSegment: Codable {
    let kind: TelemetryTimelineKind
    let value: TelemetryTimelineValue
    let startOffsetSeconds: Int
}

private enum TelemetrySkinUsageContext: String, Codable {
    case window
    case fullscreen
}

private struct TelemetrySkinUsageRecord: Codable {
    let skinID: String
    let context: TelemetrySkinUsageContext
    let durationSeconds: Int

    enum CodingKeys: String, CodingKey {
        case skinID = "skin_id"
        case context
        case durationSeconds = "duration_seconds"
    }
}

@MainActor
final class TelemetryService: NSObject {
    static let shared = TelemetryService()

    private let consentStore = TelemetryConsentStore()
    private let identityStore = AnonymousInstallIdentityStore()
    private let queue = TelemetryLocalQueue()
    private let recoveryStore = TelemetryRecoveryStore()
    private let uploader = TelemetryUploader()
    private var accumulator: SessionMetricsAccumulator?
    private weak var playbackCoordinator: PlaybackCoordinator?
    private var checkpointTimer: Timer?
    private var uploadTask: Task<Void, Never>?

    var isTelemetryEnabled: Bool {
        consentStore.isEnabled
    }

    var anonymousInstallID: String {
        identityStore.installID
    }

    private override init() {
        super.init()
    }

    func configure(playbackCoordinator: PlaybackCoordinator) {
        self.playbackCoordinator = playbackCoordinator
        playbackCoordinator.onTelemetryPlaybackStateChanged = { [weak self] source, isPlaying in
            Task { @MainActor in
                self?.updatePlaybackState(source: source, isPlaying: isPlaying)
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        recoverPreviousSessionIfNeeded()
        enqueueInstallSeenIfNeeded()
        if consentStore.isEnabled {
            startSessionIfNeeded()
            flushQueue()
        } else {
            queue.keepOnlyInstallSeenEvents()
            flushInstallSeenQueue()
        }
    }

    func setTelemetryEnabled(_ enabled: Bool) {
        guard consentStore.isEnabled != enabled else { return }
        consentStore.isEnabled = enabled

        if enabled {
            Log.info("[Telemetry] anonymous telemetry enabled", category: .telemetry)
            enqueueInstallSeenIfNeeded()
            startSessionIfNeeded()
            flushQueue()
            DiagnosticsService.shared.handleTelemetryConsentChanged(true)
        } else {
            Log.info("[Telemetry] anonymous telemetry disabled", category: .telemetry)
            uploadTask?.cancel()
            uploadTask = nil
            accumulator = nil
            checkpointTimer?.invalidate()
            checkpointTimer = nil
            queue.keepOnlyInstallSeenEvents()
            recoveryStore.clear()
            enqueueInstallSeenIfNeeded()
            flushInstallSeenQueue()
            DiagnosticsService.shared.handleTelemetryConsentChanged(false)
        }
    }

    func endSession(reason: TelemetrySessionEndReason) {
        guard consentStore.isEnabled, let summary = accumulator?.finish(reason: reason) else { return }
        queue.enqueue(summaryEvent(from: summary))
        accumulator = nil
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        recoveryStore.clear()
        if reason == .appTerminated {
            flushQueueSynchronouslyForTermination()
        } else {
            flushQueue()
        }
    }

    private func startSessionIfNeeded() {
        guard consentStore.isEnabled, accumulator == nil else { return }
        enqueueInstallSeenIfNeeded()

        let source = playbackCoordinator?.activeSource ?? .local
        let isPlaying = playbackCoordinator?.presentation.isPlaying ?? false
        let sessionID = UUID().uuidString
        let now = Date()
        accumulator = SessionMetricsAccumulator(
            sessionID: sessionID,
            startedAt: now,
            foregroundActive: NSApp.isActive,
            mode: TelemetryPlaybackMode(source: source),
            isPlaying: isPlaying,
            windowSkinID: currentWindowSkinID(),
            fullscreenSkinID: currentFullscreenSkinID(),
            skinContext: currentSkinUsageContext()
        )
        queue.enqueue(baseEvent(
            eventID: UUID().uuidString,
            occurredAt: now,
            sessionID: sessionID,
            eventType: "app_session_start",
            properties: [:]
        ))
        checkpoint()
        startCheckpointTimer()
    }

    private func recoverPreviousSessionIfNeeded() {
        guard consentStore.isEnabled, let checkpoint = recoveryStore.load() else { return }
        let summary = checkpoint.recoveredSummary()
        queue.enqueue(summaryEvent(from: summary))
        recoveryStore.clear()
    }

    private func enqueueInstallSeenIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: TelemetryDefaults.installSeenAcknowledgedKey) else { return }
        let defaults = UserDefaults.standard
        let eventID = defaults.string(forKey: TelemetryDefaults.installSeenEventIDKey) ?? UUID().uuidString
        defaults.set(eventID, forKey: TelemetryDefaults.installSeenEventIDKey)
        guard !queue.contains(eventID: eventID) else { return }
        queue.enqueue(baseEvent(
            eventID: eventID,
            occurredAt: Date(),
            sessionID: nil,
            eventType: "app_install_seen",
            properties: [:]
        ))
    }

    private func updatePlaybackState(source: PlaybackSource, isPlaying: Bool) {
        guard consentStore.isEnabled else { return }
        startSessionIfNeeded()
        accumulator?.update(mode: TelemetryPlaybackMode(source: source), isPlaying: isPlaying)
        checkpoint()
    }

    @objc private func appDidBecomeActive() {
        guard consentStore.isEnabled else { return }
        startSessionIfNeeded()
        accumulator?.updateForeground(isActive: true)
        checkpoint()
    }

    @objc private func appDidResignActive() {
        guard consentStore.isEnabled else { return }
        accumulator?.updateForeground(isActive: false)
        checkpoint()
        flushQueue()
    }

    func updateSkinState() {
        guard consentStore.isEnabled else { return }
        startSessionIfNeeded()
        accumulator?.updateSkins(
            windowSkinID: currentWindowSkinID(),
            fullscreenSkinID: currentFullscreenSkinID(),
            context: currentSkinUsageContext()
        )
        checkpoint()
    }

    private func startCheckpointTimer() {
        checkpointTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkpoint()
                self?.flushQueue()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        checkpointTimer = timer
    }

    private func checkpoint() {
        guard var accumulator else { return }
        recoveryStore.save(accumulator.checkpoint())
        self.accumulator = accumulator
    }

    private func flushQueue() {
        guard consentStore.isEnabled, uploadTask == nil else { return }
        let events = queue.pendingEvents()
        guard !events.isEmpty else { return }

        uploadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await uploader.upload(events: events)
                try Task.checkCancellation()
                await MainActor.run {
                    self.applyUploadResponse(response, uploadedEvents: events)
                    self.uploadTask = nil
                    if !self.queue.pendingEvents().isEmpty {
                        self.flushQueue()
                    }
                }
            } catch {
                await MainActor.run {
                    Log.warning("[Telemetry] upload failed: \(error)", category: .telemetry)
                    self.uploadTask = nil
                }
            }
        }
    }

    private func flushQueueSynchronouslyForTermination() {
        guard consentStore.isEnabled else { return }
        let events = queue.pendingEvents()
        guard !events.isEmpty else { return }

        do {
            let response = try uploader.uploadSynchronously(events: events, timeout: 3)
            applyUploadResponse(response, uploadedEvents: events)
        } catch {
            Log.warning("[Telemetry] termination upload failed: \(error)", category: .telemetry)
        }
    }

    private func flushInstallSeenQueue() {
        guard uploadTask == nil else { return }
        let events = queue.pendingEvents().filter { $0.eventType == "app_install_seen" }
        guard !events.isEmpty else { return }

        uploadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await uploader.upload(events: events)
                try Task.checkCancellation()
                await MainActor.run {
                    self.applyUploadResponse(response, uploadedEvents: events)
                    self.uploadTask = nil
                }
            } catch {
                await MainActor.run {
                    Log.warning("[Telemetry] install seen upload failed: \(error)", category: .telemetry)
                    self.uploadTask = nil
                }
            }
        }
    }

    private func applyUploadResponse(_ response: TelemetryUploadResponse, uploadedEvents: [TelemetryQueuedEvent]) {
        let completedIDs = response.acceptedEvents.map(\.eventID)
        queue.remove(eventIDs: completedIDs)
        for rejected in response.rejectedEvents {
            if uploadedEvents.indices.contains(rejected.index) {
                let event = uploadedEvents[rejected.index]
                queue.remove(eventIDs: [event.eventID])
            }
        }
        if let installSeenID = UserDefaults.standard.string(forKey: TelemetryDefaults.installSeenEventIDKey),
           completedIDs.contains(installSeenID) {
            UserDefaults.standard.set(true, forKey: TelemetryDefaults.installSeenAcknowledgedKey)
        }
    }

    private func baseEvent(
        eventID: String,
        occurredAt: Date,
        sessionID: String?,
        eventType: String,
        properties: [String: TelemetryJSONValue]
    ) -> TelemetryQueuedEvent {
        TelemetryQueuedEvent(
            eventID: eventID,
            occurredAt: occurredAt,
            installID: identityStore.installID,
            sessionID: sessionID,
            eventType: eventType,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            platform: "macOS",
            schemaVersion: 2,
            properties: properties
        )
    }

    private func summaryEvent(from summary: TelemetrySessionSummary) -> TelemetryQueuedEvent {
        baseEvent(
            eventID: UUID().uuidString,
            occurredAt: Date(),
            sessionID: summary.sessionID,
            eventType: "app_session_summary",
            properties: [
                "session_duration_seconds": .int(summary.sessionDurationSeconds),
                "foreground_duration_seconds": .int(summary.foregroundDurationSeconds),
                "mode_duration_seconds": .object([
                    "local": .int(summary.localModeDurationSeconds),
                    "apple_music": .int(summary.appleMusicModeDurationSeconds),
                    "external": .int(summary.externalModeDurationSeconds)
                ]),
                "playback_duration_seconds": .object([
                    "total": .int(summary.playbackTotalDurationSeconds),
                    "local": .int(summary.playbackLocalDurationSeconds),
                    "apple_music": .int(summary.playbackAppleMusicDurationSeconds),
                    "external": .int(summary.playbackExternalDurationSeconds)
                ]),
                "session_end_reason": .string(summary.endReason.rawValue),
                "timeline_segments": .array(summary.timelineSegments.map { segment in
                    .object([
                        "kind": .string(segment.kind.rawValue),
                        "value": .string(segment.value.rawValue),
                        "start_offset_seconds": .int(segment.startOffsetSeconds),
                        "end_offset_seconds": .int(segment.endOffsetSeconds)
                    ])
                }),
                "skin_usage": .array(summary.skinUsage.map { usage in
                    .object([
                        "skin_id": .string(usage.skinID),
                        "context": .string(usage.context.rawValue),
                        "duration_seconds": .int(usage.durationSeconds)
                    ])
                })
            ]
        )
    }

    private func currentWindowSkinID() -> String {
        SkinRegistry.skin(for: AppSettings.shared.selectedNowPlayingSkinID).id
    }

    private func currentFullscreenSkinID() -> String {
        SkinRegistry.fullscreenSkin(for: AppSettings.shared.fullscreen.skinID).id
    }

    private func currentSkinUsageContext() -> TelemetrySkinUsageContext {
        // Embedded fullscreen uses the fullscreen player UI and fullscreen skin,
        // so it is intentionally counted as fullscreen skin usage.
        FullscreenWindowManager.shared.usesFullscreenPlayerUI ? .fullscreen : .window
    }
}

private enum TelemetryDefaults {
    static let consentKey = "telemetry.anonymousUsageEnabled"
    static let installIDKey = "telemetry.anonymousInstallID"
    static let installSeenAcknowledgedKey = "telemetry.installSeenAcknowledged"
    static let installSeenEventIDKey = "telemetry.installSeenEventID"
}

private final class TelemetryConsentStore {
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: TelemetryDefaults.consentKey) }
        set { UserDefaults.standard.set(newValue, forKey: TelemetryDefaults.consentKey) }
    }
}

private final class AnonymousInstallIdentityStore {
    var installID: String {
        if let existing = UserDefaults.standard.string(forKey: TelemetryDefaults.installIDKey),
           UUID(uuidString: existing) != nil {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: TelemetryDefaults.installIDKey)
        return newID
    }

}

private struct SessionMetricsAccumulator {
    static let maxTimelineSegments = 300

    private(set) var sessionID: String
    private(set) var startedAt: Date
    private var lastCheckpointAt: Date
    private var foregroundActive: Bool
    private var mode: TelemetryPlaybackMode
    private var isPlaying: Bool
    private var foregroundDuration: TimeInterval = 0
    private var localModeDuration: TimeInterval = 0
    private var appleMusicModeDuration: TimeInterval = 0
    private var externalModeDuration: TimeInterval = 0
    private var playbackLocalDuration: TimeInterval = 0
    private var playbackAppleMusicDuration: TimeInterval = 0
    private var playbackExternalDuration: TimeInterval = 0
    private var timelineSegments: [TelemetryTimelineSegment] = []
    private var openTimelineSegments: [TelemetryOpenTimelineSegment] = []
    private var timelineLimitReached = false
    private var windowSkinID: String
    private var fullscreenSkinID: String
    private var skinContext: TelemetrySkinUsageContext
    private var skinUsageDurations: [String: TimeInterval] = [:]

    init(
        sessionID: String,
        startedAt: Date,
        foregroundActive: Bool,
        mode: TelemetryPlaybackMode,
        isPlaying: Bool,
        windowSkinID: String,
        fullscreenSkinID: String,
        skinContext: TelemetrySkinUsageContext
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.lastCheckpointAt = startedAt
        self.foregroundActive = foregroundActive
        self.mode = mode
        self.isPlaying = isPlaying
        self.windowSkinID = windowSkinID
        self.fullscreenSkinID = fullscreenSkinID
        self.skinContext = skinContext
        self.openTimelineSegments = [
            TelemetryOpenTimelineSegment(
                kind: .foreground,
                value: TelemetryTimelineValue(foregroundActive: foregroundActive),
                startOffsetSeconds: 0
            ),
            TelemetryOpenTimelineSegment(
                kind: .mode,
                value: TelemetryTimelineValue(mode: mode),
                startOffsetSeconds: 0
            ),
            TelemetryOpenTimelineSegment(
                kind: .playback,
                value: TelemetryTimelineValue(isPlaying: isPlaying),
                startOffsetSeconds: 0
            )
        ]
    }

    mutating func updateForeground(isActive: Bool) {
        let now = Date()
        settle(now: now)
        transitionTimeline(
            kind: .foreground,
            value: TelemetryTimelineValue(foregroundActive: isActive),
            at: now
        )
        foregroundActive = isActive
    }

    mutating func update(mode: TelemetryPlaybackMode, isPlaying: Bool) {
        let now = Date()
        settle(now: now)
        transitionTimeline(kind: .mode, value: TelemetryTimelineValue(mode: mode), at: now)
        transitionTimeline(kind: .playback, value: TelemetryTimelineValue(isPlaying: isPlaying), at: now)
        self.mode = mode
        self.isPlaying = isPlaying
    }

    mutating func updateSkins(
        windowSkinID: String,
        fullscreenSkinID: String,
        context: TelemetrySkinUsageContext
    ) {
        let now = Date()
        settle(now: now)
        self.windowSkinID = windowSkinID
        self.fullscreenSkinID = fullscreenSkinID
        self.skinContext = context
    }

    mutating func finish(reason: TelemetrySessionEndReason) -> TelemetrySessionSummary {
        let now = Date()
        settle(now: now)
        closeOpenTimelineSegments(at: now)
        return summary(reason: reason)
    }

    mutating func checkpoint() -> TelemetrySessionCheckpoint {
        settle()
        return TelemetrySessionCheckpoint(
            sessionID: sessionID,
            startedAt: startedAt,
            lastCheckpointAt: lastCheckpointAt,
            foregroundActive: foregroundActive,
            mode: mode,
            isPlaying: isPlaying,
            foregroundDurationSeconds: Int(foregroundDuration.rounded()),
            localModeDurationSeconds: Int(localModeDuration.rounded()),
            appleMusicModeDurationSeconds: Int(appleMusicModeDuration.rounded()),
            externalModeDurationSeconds: Int(externalModeDuration.rounded()),
            playbackLocalDurationSeconds: Int(playbackLocalDuration.rounded()),
            playbackAppleMusicDurationSeconds: Int(playbackAppleMusicDuration.rounded()),
            playbackExternalDurationSeconds: Int(playbackExternalDuration.rounded()),
            timelineSegments: timelineSegments,
            openTimelineSegments: openTimelineSegments,
            timelineLimitReached: timelineLimitReached,
            windowSkinID: windowSkinID,
            fullscreenSkinID: fullscreenSkinID,
            skinContext: skinContext,
            skinUsageDurations: skinUsageDurations
        )
    }

    private mutating func settle(now: Date = Date()) {
        let delta = max(0, min(now.timeIntervalSince(lastCheckpointAt), 24 * 60 * 60))
        if foregroundActive {
            foregroundDuration += delta
        }
        switch mode {
        case .local:
            localModeDuration += delta
            if isPlaying { playbackLocalDuration += delta }
        case .appleMusic:
            appleMusicModeDuration += delta
            if isPlaying { playbackAppleMusicDuration += delta }
        case .external:
            externalModeDuration += delta
            if isPlaying { playbackExternalDuration += delta }
        }
        skinUsageDurations[skinUsageKey(context: skinContext, skinID: currentSkinIDForContext()), default: 0] += delta
        lastCheckpointAt = now
    }

    private func offsetSeconds(at date: Date) -> Int {
        Int(max(0, date.timeIntervalSince(startedAt)).rounded())
    }

    private mutating func transitionTimeline(
        kind: TelemetryTimelineKind,
        value: TelemetryTimelineValue,
        at date: Date
    ) {
        guard !timelineLimitReached else { return }
        let offset = offsetSeconds(at: date)
        guard let openIndex = openTimelineSegments.firstIndex(where: { $0.kind == kind }) else {
            openTimelineSegments.append(TelemetryOpenTimelineSegment(
                kind: kind,
                value: value,
                startOffsetSeconds: offset
            ))
            return
        }

        let current = openTimelineSegments[openIndex]
        guard current.value != value else { return }
        appendClosedSegment(
            kind: current.kind,
            value: current.value,
            startOffsetSeconds: current.startOffsetSeconds,
            endOffsetSeconds: max(offset, current.startOffsetSeconds)
        )
        openTimelineSegments[openIndex] = TelemetryOpenTimelineSegment(
            kind: kind,
            value: value,
            startOffsetSeconds: offset
        )
    }

    private mutating func closeOpenTimelineSegments(at date: Date) {
        guard !timelineLimitReached else { return }
        let offset = offsetSeconds(at: date)
        for openSegment in openTimelineSegments {
            appendClosedSegment(
                kind: openSegment.kind,
                value: openSegment.value,
                startOffsetSeconds: openSegment.startOffsetSeconds,
                endOffsetSeconds: max(offset, openSegment.startOffsetSeconds)
            )
        }
        openTimelineSegments.removeAll()
    }

    private mutating func appendClosedSegment(
        kind: TelemetryTimelineKind,
        value: TelemetryTimelineValue,
        startOffsetSeconds: Int,
        endOffsetSeconds: Int
    ) {
        guard endOffsetSeconds > startOffsetSeconds else { return }
        if let last = timelineSegments.last,
           last.kind == kind,
           last.value == value,
           last.endOffsetSeconds == startOffsetSeconds {
            timelineSegments[timelineSegments.count - 1] = TelemetryTimelineSegment(
                kind: kind,
                value: value,
                startOffsetSeconds: last.startOffsetSeconds,
                endOffsetSeconds: endOffsetSeconds
            )
            return
        }
        guard timelineSegments.count < Self.maxTimelineSegments else {
            timelineLimitReached = true
            Log.warning("[Telemetry] timeline segment limit reached; remaining fine-grained segments dropped", category: .telemetry)
            return
        }
        timelineSegments.append(TelemetryTimelineSegment(
            kind: kind,
            value: value,
            startOffsetSeconds: startOffsetSeconds,
            endOffsetSeconds: endOffsetSeconds
        ))
    }

    private func summary(reason: TelemetrySessionEndReason) -> TelemetrySessionSummary {
        let playbackTotal = playbackLocalDuration + playbackAppleMusicDuration + playbackExternalDuration
        return TelemetrySessionSummary(
            sessionID: sessionID,
            sessionDurationSeconds: Int(max(0, Date().timeIntervalSince(startedAt)).rounded()),
            foregroundDurationSeconds: Int(foregroundDuration.rounded()),
            localModeDurationSeconds: Int(localModeDuration.rounded()),
            appleMusicModeDurationSeconds: Int(appleMusicModeDuration.rounded()),
            externalModeDurationSeconds: Int(externalModeDuration.rounded()),
            playbackTotalDurationSeconds: Int(playbackTotal.rounded()),
            playbackLocalDurationSeconds: Int(playbackLocalDuration.rounded()),
            playbackAppleMusicDurationSeconds: Int(playbackAppleMusicDuration.rounded()),
            playbackExternalDurationSeconds: Int(playbackExternalDuration.rounded()),
            endReason: reason,
            timelineSegments: timelineSegments,
            skinUsage: skinUsageSummary()
        )
    }

    private func currentSkinIDForContext() -> String {
        switch skinContext {
        case .window:
            return windowSkinID
        case .fullscreen:
            return fullscreenSkinID
        }
    }

    private func skinUsageKey(context: TelemetrySkinUsageContext, skinID: String) -> String {
        "\(context.rawValue)|\(skinID)"
    }

    private func skinUsageSummary() -> [TelemetrySkinUsageRecord] {
        skinUsageDurations.compactMap { key, duration in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let context = TelemetrySkinUsageContext(rawValue: parts[0]) else {
                return nil
            }
            let seconds = Int(duration.rounded())
            guard seconds > 0 else { return nil }
            return TelemetrySkinUsageRecord(
                skinID: parts[1],
                context: context,
                durationSeconds: seconds
            )
        }
        .sorted {
            if $0.context.rawValue == $1.context.rawValue {
                return $0.skinID < $1.skinID
            }
            return $0.context.rawValue < $1.context.rawValue
        }
    }
}

private struct TelemetrySessionSummary {
    let sessionID: String
    let sessionDurationSeconds: Int
    let foregroundDurationSeconds: Int
    let localModeDurationSeconds: Int
    let appleMusicModeDurationSeconds: Int
    let externalModeDurationSeconds: Int
    let playbackTotalDurationSeconds: Int
    let playbackLocalDurationSeconds: Int
    let playbackAppleMusicDurationSeconds: Int
    let playbackExternalDurationSeconds: Int
    let endReason: TelemetrySessionEndReason
    let timelineSegments: [TelemetryTimelineSegment]
    let skinUsage: [TelemetrySkinUsageRecord]
}

private struct TelemetrySessionCheckpoint: Codable {
    let sessionID: String
    let startedAt: Date
    let lastCheckpointAt: Date
    let foregroundActive: Bool
    let mode: TelemetryPlaybackMode
    let isPlaying: Bool
    let foregroundDurationSeconds: Int
    let localModeDurationSeconds: Int
    let appleMusicModeDurationSeconds: Int
    let externalModeDurationSeconds: Int
    let playbackLocalDurationSeconds: Int
    let playbackAppleMusicDurationSeconds: Int
    let playbackExternalDurationSeconds: Int
    let timelineSegments: [TelemetryTimelineSegment]
    let openTimelineSegments: [TelemetryOpenTimelineSegment]
    let timelineLimitReached: Bool
    let windowSkinID: String
    let fullscreenSkinID: String
    let skinContext: TelemetrySkinUsageContext
    let skinUsageDurations: [String: TimeInterval]

    func recoveredSummary() -> TelemetrySessionSummary {
        let sessionDuration = Int(max(0, lastCheckpointAt.timeIntervalSince(startedAt)).rounded())
        let playbackTotal = playbackLocalDurationSeconds
            + playbackAppleMusicDurationSeconds
            + playbackExternalDurationSeconds
        let recoveredTimelineSegments = Self.closeOpenTimelineSegments(
            closedSegments: timelineSegments,
            openSegments: openTimelineSegments,
            sessionDurationSeconds: sessionDuration,
            limitReached: timelineLimitReached
        )
        return TelemetrySessionSummary(
            sessionID: sessionID,
            sessionDurationSeconds: sessionDuration,
            foregroundDurationSeconds: foregroundDurationSeconds,
            localModeDurationSeconds: localModeDurationSeconds,
            appleMusicModeDurationSeconds: appleMusicModeDurationSeconds,
            externalModeDurationSeconds: externalModeDurationSeconds,
            playbackTotalDurationSeconds: playbackTotal,
            playbackLocalDurationSeconds: playbackLocalDurationSeconds,
            playbackAppleMusicDurationSeconds: playbackAppleMusicDurationSeconds,
            playbackExternalDurationSeconds: playbackExternalDurationSeconds,
            endReason: .recoveredAfterUngracefulExit,
            timelineSegments: recoveredTimelineSegments,
            skinUsage: recoveredSkinUsageSummary()
        )
    }

    private static func closeOpenTimelineSegments(
        closedSegments: [TelemetryTimelineSegment],
        openSegments: [TelemetryOpenTimelineSegment],
        sessionDurationSeconds: Int,
        limitReached: Bool
    ) -> [TelemetryTimelineSegment] {
        guard !limitReached else { return closedSegments }
        var segments = closedSegments
        for openSegment in openSegments {
            let endOffset = max(sessionDurationSeconds, openSegment.startOffsetSeconds)
            guard endOffset > openSegment.startOffsetSeconds else { continue }
            guard segments.count < SessionMetricsAccumulator.maxTimelineSegments else { break }
            segments.append(TelemetryTimelineSegment(
                kind: openSegment.kind,
                value: openSegment.value,
                startOffsetSeconds: openSegment.startOffsetSeconds,
                endOffsetSeconds: endOffset
            ))
        }
        return segments
    }

    private func recoveredSkinUsageSummary() -> [TelemetrySkinUsageRecord] {
        skinUsageDurations.compactMap { key, duration in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let context = TelemetrySkinUsageContext(rawValue: parts[0]) else {
                return nil
            }
            let seconds = Int(duration.rounded())
            guard seconds > 0 else { return nil }
            return TelemetrySkinUsageRecord(
                skinID: parts[1],
                context: context,
                durationSeconds: seconds
            )
        }
    }
}

private enum TelemetryJSONValue: Codable {
    case string(String)
    case int(Int)
    case object([String: TelemetryJSONValue])
    case array([TelemetryJSONValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([TelemetryJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: TelemetryJSONValue].self))
        }
    }
}

private struct TelemetryQueuedEvent: Codable {
    let eventID: String
    let occurredAt: Date
    let installID: String
    let sessionID: String?
    let eventType: String
    let appVersion: String
    let buildNumber: String?
    let platform: String
    let schemaVersion: Int
    let properties: [String: TelemetryJSONValue]

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case occurredAt = "occurred_at"
        case installID = "install_id"
        case sessionID = "session_id"
        case eventType = "event_type"
        case appVersion = "app_version"
        case buildNumber = "build_number"
        case platform
        case schemaVersion = "schema_version"
        case properties
    }
}

private final class TelemetryLocalQueue {
    private let maxEvents = 200
    private let fileURL = TelemetryFilePaths.applicationSupport
        .appendingPathComponent("telemetry-queue.json")

    func enqueue(_ event: TelemetryQueuedEvent) {
        var events = pendingEvents()
        events.append(event)
        if events.count > maxEvents {
            events = Array(events.suffix(maxEvents))
        }
        save(events)
    }

    func pendingEvents() -> [TelemetryQueuedEvent] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TelemetryQueuedEvent].self, from: data)) ?? []
    }

    func remove(eventIDs: [String]) {
        let removed = Set(eventIDs)
        save(pendingEvents().filter { !removed.contains($0.eventID) })
    }

    func contains(eventID: String) -> Bool {
        pendingEvents().contains { $0.eventID == eventID }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func keepOnlyInstallSeenEvents() {
        save(pendingEvents().filter { $0.eventType == "app_install_seen" })
    }

    private func save(_ events: [TelemetryQueuedEvent]) {
        TelemetryFilePaths.ensureApplicationSupportExists()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(events) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

private final class TelemetryRecoveryStore {
    private let fileURL = TelemetryFilePaths.applicationSupport
        .appendingPathComponent("telemetry-session-checkpoint.json")

    func save(_ checkpoint: TelemetrySessionCheckpoint) {
        TelemetryFilePaths.ensureApplicationSupportExists()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(checkpoint) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func load() -> TelemetrySessionCheckpoint? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TelemetrySessionCheckpoint.self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private enum TelemetryFilePaths {
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "kmgccc_player"
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    static func ensureApplicationSupportExists() {
        try? FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
    }
}

private struct TelemetryUploadRequest: Codable {
    let client: TelemetryUploadClient
    let events: [TelemetryQueuedEvent]
}

private struct TelemetryUploadClient: Codable {
    let appVersion: String
    let buildNumber: String?
    let platform: String
    let schemaVersion: Int

    enum CodingKeys: String, CodingKey {
        case appVersion = "app_version"
        case buildNumber = "build_number"
        case platform
        case schemaVersion = "schema_version"
    }
}

private struct TelemetryUploadResponse: Decodable {
    let success: Bool
    let acceptedCount: Int
    let duplicateCount: Int
    let rejectedCount: Int
    let acceptedEvents: [TelemetryAcceptedEvent]
    let rejectedEvents: [TelemetryRejectedEvent]

    enum CodingKeys: String, CodingKey {
        case success
        case acceptedCount = "accepted_count"
        case duplicateCount = "duplicate_count"
        case rejectedCount = "rejected_count"
        case acceptedEvents = "accepted_events"
        case rejectedEvents = "rejected_events"
    }
}

private struct TelemetryAcceptedEvent: Decodable {
    let eventID: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case status
    }
}

private struct TelemetryRejectedEvent: Decodable {
    let index: Int
    let reason: String
}

private final class TelemetryUploader {
    private let endpoint = URL(string: "https://player.kmgccc.cn/api/v1/telemetry/events/batch")!
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration)
    }

    func upload(events: [TelemetryQueuedEvent]) async throws -> TelemetryUploadResponse {
        let request = try makeRequest(events: events, timeout: 5)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        return try decoder.decode(TelemetryUploadResponse.self, from: data)
    }

    func uploadSynchronously(events: [TelemetryQueuedEvent], timeout: TimeInterval) throws -> TelemetryUploadResponse {
        let request = try makeRequest(events: events, timeout: timeout)
        let semaphore = DispatchSemaphore(value: 0)
        var receivedData: Data?
        var receivedStatusCode: Int?
        var receivedError: Error?

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                receivedError = error
                return
            }
            receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
            receivedData = data
        }
        task.resume()

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw URLError(.timedOut)
        }
        if let receivedError {
            throw receivedError
        }
        guard let statusCode = receivedStatusCode,
              (200..<300).contains(statusCode),
              let receivedData else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(TelemetryUploadResponse.self, from: receivedData)
    }

    private func makeRequest(events: [TelemetryQueuedEvent], timeout: TimeInterval) throws -> URLRequest {
        guard let first = events.first else {
            throw URLError(.badURL)
        }

        let requestBody = TelemetryUploadRequest(
            client: TelemetryUploadClient(
                appVersion: first.appVersion,
                buildNumber: first.buildNumber,
                platform: "macOS",
                schemaVersion: 2
            ),
            events: events
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(requestBody)
        return request
    }
}

private extension TelemetryUploadResponse {
    static let empty = TelemetryUploadResponse(
        success: true,
        acceptedCount: 0,
        duplicateCount: 0,
        rejectedCount: 0,
        acceptedEvents: [],
        rejectedEvents: []
    )
}
