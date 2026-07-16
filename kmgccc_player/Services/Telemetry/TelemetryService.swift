//
//  TelemetryService.swift
//  myPlayer2
//
//  kmgccc_player - Consent-based anonymous usage telemetry.
//

import AppKit
import Foundation

enum TelemetryPlaybackMode: String, Codable, Sendable {
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

enum TelemetrySessionEndReason: String, Codable, Sendable {
    case appTerminated = "app_terminated"
    case recoveredAfterUngracefulExit = "recovered_after_ungraceful_exit"
    case other
}

private enum TelemetryTimelineKind: String, Codable, Sendable {
    case foreground
    case mode
    case playback
}

private enum TelemetryTimelineValue: String, Codable, Sendable {
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

private struct TelemetryTimelineSegment: Codable, Sendable {
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

private struct TelemetryOpenTimelineSegment: Codable, Sendable {
    let kind: TelemetryTimelineKind
    let value: TelemetryTimelineValue
    let startOffsetSeconds: Int
}

private enum TelemetrySkinUsageContext: String, Codable, Sendable {
    case window
    case fullscreen
}

private struct TelemetrySkinUsageRecord: Codable, Sendable {
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
    private lazy var signer = TelemetryRequestSigner(keyStore: .shared)
    private var accumulator: SessionMetricsAccumulator?
    private weak var playbackCoordinator: PlaybackCoordinator?
    private var isWindowNowPlayingVisible = false
    private var checkpointTimer: Timer?
    private var uploadTask: Task<Void, Never>?
    // Coarse anonymous device info, computed once per launch. Only attached to
    // uploads when telemetry consent is enabled (never to the install-seen-only
    // path used for non-consenting users).
    private lazy var deviceSnapshot: DeviceTelemetrySnapshot = DeviceTelemetryProvider.current()

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
        #if DEBUG
        TelemetryRequestSigner.runSelfCheck()
        #endif
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
            // The summary is already durable in the local queue. Do not perform
            // network I/O while AppKit is synchronously terminating the process;
            // the next launch flushes this queue asynchronously.
            Log.info(
                "[Telemetry] session persisted for next launch; skipping termination upload",
                category: .telemetry
            )
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

    func setWindowNowPlayingVisible(_ isVisible: Bool) {
        guard isWindowNowPlayingVisible != isVisible else { return }
        isWindowNowPlayingVisible = isVisible
        updateSkinState()
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

    /// Ensures the signing key is registered before signed uploads. Idempotent;
    /// no-ops once UserDefaults records success. Safe for install-seen-only uploads
    /// because those are already sent even when usage telemetry is disabled.
    private func ensureRegistered() async -> Bool {
        // Force key load/generation first. publicKeyBase64() calls privateKey()
        // internally, which generates a new software key and sets
        // needsRegistration if the file is absent/corrupted (new install or
        // migration from the old Secure Enclave / Keychain-backed store).
        guard TelemetrySigningKeyStore.shared.publicKeyBase64() != nil else {
            Log.error("[Telemetry] ensureRegistered: publicKeyBase64() returned nil, cannot register", category: .telemetry)
            return false
        }

        // If a new key was just generated, force re-registration regardless of
        // the stored UserDefaults flag - the server has no record of this key.
        if TelemetrySigningKeyStore.shared.needsRegistration {
            Log.info("[Telemetry] ensureRegistered: new key generated, forcing re-registration", category: .telemetry)
            UserDefaults.standard.set(0, forKey: TelemetryDefaults.signingRegisteredKey)
        }

        let registeredVersion = UserDefaults.standard.integer(forKey: TelemetryDefaults.signingRegisteredKey)
        if registeredVersion >= 1 {
            Log.info("[Telemetry] ensureRegistered fast-path ok (registeredVersion=\(registeredVersion))", category: .telemetry)
            return true
        }
        Log.info("[Telemetry] ensureRegistered calling registerSigningKey (registeredVersion was \(registeredVersion))", category: .telemetry)
        let outcome = await uploader.registerSigningKey(clientID: identityStore.installID, signer: signer)
        switch outcome {
        case .success:
            UserDefaults.standard.set(1, forKey: TelemetryDefaults.signingRegisteredKey)
            Log.info("[Telemetry] ensureRegistered registerSigningKey succeeded, registeredVersion=1", category: .telemetry)
            return true
        case .conflict:
            // HTTP 409: a different key is already bound to this client_id on the
            // server. This happens during migration (SE -> software key), reinstall,
            // or restore-from-backup. Reset the install_id so the next registration
            // uses a fresh TOFU first-bind, then retry once.
            Log.warning("[Telemetry] ensureRegistered: 409 key conflict, resetting install_id for fresh TOFU", category: .telemetry)
            UserDefaults.standard.removeObject(forKey: TelemetryDefaults.installIDKey)
            let newClientID = identityStore.installID
            Log.info("[Telemetry] ensureRegistered: retrying with new install_id=\(newClientID.prefix(8))", category: .telemetry)
            let retry = await uploader.registerSigningKey(clientID: newClientID, signer: signer)
            if retry == .success {
                UserDefaults.standard.set(1, forKey: TelemetryDefaults.signingRegisteredKey)
                Log.info("[Telemetry] ensureRegistered: retry succeeded, registeredVersion=1", category: .telemetry)
                return true
            }
            Log.warning("[Telemetry] ensureRegistered: retry returned \(retry)", category: .telemetry)
            return false
        case .failure:
            Log.warning("[Telemetry] ensureRegistered registerSigningKey returned failure", category: .telemetry)
            return false
        }
    }

    /// If any queued events carry a stale install_id (from before a 409 conflict
    /// reset), re-tag them with the current install_id and persist the change.
    /// Returns the events to upload. No-op when IDs already match.
    private func rewriteInstallIDIfNeeded(events: [TelemetryQueuedEvent], to clientID: String) -> [TelemetryQueuedEvent] {
        guard events.contains(where: { $0.installID != clientID }) else { return events }
        let staleCount = events.filter { $0.installID != clientID }.count
        Log.info("[Telemetry] re-tagging \(staleCount)/\(events.count) events to install_id=\(clientID.prefix(8))", category: .telemetry)
        var rewritten = events
        for i in rewritten.indices {
            rewritten[i].installID = clientID
        }
        queue.replaceAll(rewritten)
        return rewritten
    }

    private func flushQueue() {
        guard consentStore.isEnabled, uploadTask == nil else { return }
        let events = queue.pendingEvents()
        guard !events.isEmpty else { return }

        let device = deviceSnapshot
        uploadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let canSign = await self.ensureRegistered()
                // Re-read install_id AFTER ensureRegistered, because a 409 conflict
                // may have reset it. Events queued before the reset still carry the
                // old ID and must be re-tagged, otherwise the server rejects the
                // signed batch ("Event install_id does not match signer") or the
                // new install record shows "unknown" (events land on the old ID).
                let clientID = self.identityStore.installID
                let eventsToUpload = self.rewriteInstallIDIfNeeded(events: events, to: clientID)
                Log.info("[Telemetry] flushQueue events=\(eventsToUpload.count) canSign=\(canSign)", category: .telemetry)
                let response = try await uploader.upload(
                    events: eventsToUpload, device: device,
                    signer: canSign ? self.signer : nil,
                    clientID: canSign ? clientID : nil)
                try Task.checkCancellation()
                await MainActor.run {
                    self.applyUploadResponse(response, uploadedEvents: eventsToUpload)
                    self.uploadTask = nil
                    if !self.queue.pendingEvents().isEmpty {
                        self.flushQueue()
                    }
                }
            } catch {
                await MainActor.run {
                    if case TelemetryUploadError.unauthorized = error {
                        // Server no longer recognizes our key; re-register next flush.
                        UserDefaults.standard.set(0, forKey: TelemetryDefaults.signingRegisteredKey)
                    }
                    Log.warning("[Telemetry] upload failed: \(error)", category: .telemetry)
                    self.uploadTask = nil
                }
            }
        }
    }

    private func flushInstallSeenQueue() {
        guard uploadTask == nil else { return }
        let events = queue.pendingEvents().filter { $0.eventType == "app_install_seen" }
        guard !events.isEmpty else { return }

        uploadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let canSign = await self.ensureRegistered()
                let clientID = self.identityStore.installID
                let eventsToUpload = self.rewriteInstallIDIfNeeded(events: events, to: clientID)
                let response = try await uploader.upload(
                    events: eventsToUpload,
                    signer: canSign ? self.signer : nil,
                    clientID: canSign ? clientID : nil
                )
                try Task.checkCancellation()
                await MainActor.run {
                    self.applyUploadResponse(response, uploadedEvents: eventsToUpload)
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
            schemaVersion: 3,
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

    private func currentSkinUsageContext() -> TelemetrySkinUsageContext? {
        // Embedded fullscreen uses the fullscreen player UI and fullscreen skin,
        // so it is intentionally counted as fullscreen skin usage. Window skin
        // time is counted only while the window Now Playing host is mounted.
        if FullscreenWindowManager.shared.usesFullscreenPlayerUI {
            return .fullscreen
        }
        return isWindowNowPlayingVisible ? .window : nil
    }
}

private enum TelemetryDefaults {
    static let consentKey = "telemetry.anonymousUsageEnabled"
    static let installIDKey = "telemetry.anonymousInstallID"
    static let installSeenAcknowledgedKey = "telemetry.installSeenAcknowledged"
    static let installSeenEventIDKey = "telemetry.installSeenEventID"
    static let signingRegisteredKey = "telemetry.signingKeyRegisteredVersion"
}

private final class TelemetryConsentStore {
    var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: TelemetryDefaults.consentKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: TelemetryDefaults.consentKey)
        }
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
    private var skinContext: TelemetrySkinUsageContext?
    private var skinUsageDurations: [String: TimeInterval] = [:]

    init(
        sessionID: String,
        startedAt: Date,
        foregroundActive: Bool,
        mode: TelemetryPlaybackMode,
        isPlaying: Bool,
        windowSkinID: String,
        fullscreenSkinID: String,
        skinContext: TelemetrySkinUsageContext?
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
        context: TelemetrySkinUsageContext?
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
        if let skinContext {
            skinUsageDurations[skinUsageKey(context: skinContext, skinID: currentSkinIDForContext(skinContext)), default: 0] += delta
        }
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

    private func currentSkinIDForContext(_ context: TelemetrySkinUsageContext) -> String {
        switch context {
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
    let skinContext: TelemetrySkinUsageContext?
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

private enum TelemetryJSONValue: Codable, Sendable {
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

private struct TelemetryQueuedEvent: Codable, Sendable {
    let eventID: String
    let occurredAt: Date
    var installID: String
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

    /// Replaces all queued events. Used when the install_id changes (e.g. 409
    /// conflict reset) and queued events need to be re-tagged with the new ID.
    func replaceAll(_ events: [TelemetryQueuedEvent]) {
        save(events)
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

private struct TelemetryUploadRequest: Codable, Sendable {
    let client: TelemetryUploadClient
    let events: [TelemetryQueuedEvent]
}

private struct TelemetryUploadClient: Codable, Sendable {
    let appVersion: String
    let buildNumber: String?
    let platform: String
    let schemaVersion: Int
    // Coarse anonymous device info. Optional so old/disabled-consent payloads omit
    // them entirely (nil Optionals are dropped by JSONEncoder via encodeIfPresent).
    let deviceFamily: String?
    let chipFamily: String?
    let chipTier: String?
    let memoryGB: Int?
    let osMajor: String?

    enum CodingKeys: String, CodingKey {
        case appVersion = "app_version"
        case buildNumber = "build_number"
        case platform
        case schemaVersion = "schema_version"
        case deviceFamily = "device_family"
        case chipFamily = "chip_family"
        case chipTier = "chip_tier"
        case memoryGB = "memory_gb"
        case osMajor = "os_major"
    }
}

private struct TelemetryUploadResponse: Decodable, Sendable {
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

private struct TelemetryAcceptedEvent: Decodable, Sendable {
    let eventID: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case status
    }
}

private struct TelemetryRejectedEvent: Decodable, Sendable {
    let index: Int
    let reason: String
}

enum TelemetryUploadError: Error { case unauthorized }

/// Outcome of a TOFU public-key registration attempt.
enum TelemetryRegistrationOutcome: Sendable {
    case success       // HTTP 200 (registered or already_registered)
    case conflict      // HTTP 409 - a different key is already bound to this client_id
    case failure       // transport error, nil key/signature, or other non-200
}

private final class TelemetryUploader {
    private let endpoint = URL(string: "https://player.kmgccc.cn/api/v1/telemetry/events/batch")!
    private let registerEndpoint = URL(string: "https://player.kmgccc.cn/api/v1/telemetry/register")!
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration)
    }

    /// Registers this install's public key (TOFU). Returns .success on HTTP 200
    /// (registered or already_registered), .conflict on HTTP 409 (different key
    /// already bound), .failure on transport error or other non-200.
    func registerSigningKey(clientID: String, signer: TelemetryRequestSigner) async -> TelemetryRegistrationOutcome {
        guard let publicKey = TelemetrySigningKeyStore.shared.publicKeyBase64() else {
            Log.warning("[Telemetry] registerSigningKey: publicKeyBase64() returned nil, aborting registration", category: .telemetry)
            return .failure
        }
        let payload: [String: Any] = [
            "client_id": clientID,
            "public_key": publicKey,
            "algorithm": "ecdsa-p256-sha256",
            "key_version": 1,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]) else { return .failure }
        guard let headers = signer.sign(method: "POST",
                                        path: "/api/v1/telemetry/register",
                                        body: body, clientID: clientID) else {
            Log.warning("[Telemetry] registerSigningKey: signer.sign() returned nil, aborting registration", category: .telemetry)
            return .failure
        }
        var request = URLRequest(url: registerEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(headers.clientID, forHTTPHeaderField: "X-Client-Id")
        request.setValue(headers.timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(headers.nonce, forHTTPHeaderField: "X-Nonce")
        request.setValue(headers.signature, forHTTPHeaderField: "X-Signature")
        request.httpBody = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodySnippet = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            if statusCode == 200 {
                Log.info("[Telemetry] registerSigningKey HTTP 200 body=\(bodySnippet)", category: .telemetry)
                return .success
            }
            if statusCode == 409 {
                Log.warning("[Telemetry] registerSigningKey HTTP 409 body=\(bodySnippet)", category: .telemetry)
                return .conflict
            }
            Log.warning("[Telemetry] registerSigningKey HTTP \(statusCode) body=\(bodySnippet)", category: .telemetry)
            return .failure
        } catch {
            Log.warning("[Telemetry] registerSigningKey transport error: \(error)", category: .telemetry)
            return .failure
        }
    }

    func upload(
        events: [TelemetryQueuedEvent],
        device: DeviceTelemetrySnapshot? = nil,
        signer: TelemetryRequestSigner? = nil,
        clientID: String? = nil
    ) async throws -> TelemetryUploadResponse {
        let request = try makeRequest(events: events, timeout: 5, device: device,
                                      signer: signer, clientID: clientID)

        let (data, response) = try await session.data(for: request)
        return try Self.decodeUploadResponse(data: data, response: response)
    }

    private func makeRequest(
        events: [TelemetryQueuedEvent],
        timeout: TimeInterval,
        device: DeviceTelemetrySnapshot?,
        signer: TelemetryRequestSigner?,
        clientID: String?
    ) throws -> URLRequest {
        guard let first = events.first else {
            throw URLError(.badURL)
        }

        let requestBody = TelemetryUploadRequest(
            client: TelemetryUploadClient(
                appVersion: first.appVersion,
                buildNumber: first.buildNumber,
                platform: "macOS",
                schemaVersion: 3,
                deviceFamily: device?.deviceFamily,
                chipFamily: device?.chipFamily,
                chipTier: device?.chipTier,
                memoryGB: device?.memoryGB,
                osMajor: device?.osMajor
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

        if let signer, let clientID,
           let headers = signer.sign(method: "POST",
                                     path: "/api/v1/telemetry/events/batch",
                                     body: request.httpBody ?? Data(),
                                     clientID: clientID) {
            request.setValue(headers.clientID, forHTTPHeaderField: "X-Client-Id")
            request.setValue(headers.timestamp, forHTTPHeaderField: "X-Timestamp")
            request.setValue(headers.nonce, forHTTPHeaderField: "X-Nonce")
            request.setValue(headers.signature, forHTTPHeaderField: "X-Signature")
            Log.info("[Telemetry] makeRequest signed: 4 headers added (X-Client-Id, X-Timestamp, X-Nonce, X-Signature) client=\(clientID.prefix(8))", category: .telemetry)
        } else {
            let signerNil = signer == nil
            let clientIDNil = clientID == nil
            Log.warning("[Telemetry] makeRequest UNSIGNED: signerNil=\(signerNil) clientIDNil=\(clientIDNil) - no signature headers will be sent", category: .telemetry)
        }
        return request
    }

    private static func decodeUploadResponse(
        data: Data,
        response: URLResponse
    ) throws -> TelemetryUploadResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            Log.warning("[Telemetry] upload response: not an HTTPURLResponse", category: .telemetry)
            throw URLError(.badServerResponse)
        }
        let bodySnippet = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
        if httpResponse.statusCode == 401 {
            Log.warning("[Telemetry] upload HTTP 401 body=\(bodySnippet) — server rejected signature (or requires signed)", category: .telemetry)
            throw TelemetryUploadError.unauthorized
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            Log.warning("[Telemetry] upload HTTP \(httpResponse.statusCode) body=\(bodySnippet)", category: .telemetry)
            throw URLError(.badServerResponse)
        }
        Log.info("[Telemetry] upload HTTP \(httpResponse.statusCode) accepted (signed/unsigned determined server-side)", category: .telemetry)
        let decoder = JSONDecoder()
        return try decoder.decode(TelemetryUploadResponse.self, from: data)
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
