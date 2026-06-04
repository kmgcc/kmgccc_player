//
//  DiagnosticsService.swift
//  myPlayer2
//
//  Consent-based, sanitized business failure diagnostics.
//

import AppKit
import CryptoKit
import Foundation
import ImageIO

enum DiagnosticsLevel: String, Codable, Sendable {
    case info
    case warning
    case error
    case fatal
}

enum DiagnosticsSubsystem: String, Codable, Sendable {
    case update
    case `import`
    case ncm
    case library
    case metadata
    case lyrics
    case artwork
    case amll
    case webview
    case playback
    case appleMusic = "apple_music"
    case externalPlayer = "external_player"
    case telemetry
    case settings
    case database
    case fileIO = "file_io"
    case network
    case unknown
}

enum DiagnosticsCategory: String, Codable, Sendable {
    case network
    case parse
    case validation
    case fileIO = "file_io"
    case decode
    case permission
    case timeout
    case noResults = "no_results"
    case providerFailure = "provider_failure"
    case persistence
    case lifecycle
    case navigation
    case jsBridge = "js_bridge"
    case render
    case playback
    case control
    case unknown
}

enum DiagnosticsStage: String, Codable, Sendable {
    case start
    case request
    case response
    case parse
    case search
    case download
    case decode
    case copy
    case save
    case load
    case render
    case attach
    case reload
    case cleanup
    case flush
    case migrate
    case permission
    case unknown

    case importStart = "import_start"
    case fileScan = "file_scan"
    case ncmDecode = "ncm_decode"
    case fileCopy = "file_copy"
    case metadataExtract = "metadata_extract"
    case artworkExtract = "artwork_extract"
    case libraryInsert = "library_insert"
    case rollbackCleanup = "rollback_cleanup"

    case lyricsSearch = "lyrics_search"
    case lyricsDownload = "lyrics_download"
    case lyricsParse = "lyrics_parse"
    case lyricsConvert = "lyrics_convert"
    case lyricsSave = "lyrics_save"
    case lyricsLoad = "lyrics_load"
    case lyricsRender = "lyrics_render"

    case artworkSearch = "artwork_search"
    case artworkDownload = "artwork_download"
    case artworkDecode = "artwork_decode"
    case artworkCache = "artwork_cache"
    case artworkApply = "artwork_apply"

    case amllBundleLoad = "amll_bundle_load"
    case webviewAttach = "webview_attach"
    case webviewNavigation = "webview_navigation"
    case jsBridge = "js_bridge"
    case lyricsSet = "lyrics_set"
    case renderUpdate = "render_update"
    case webcontentTerminated = "webcontent_terminated"

    case assetLoad = "asset_load"
    case decoderPrepare = "decoder_prepare"
    case playbackStart = "playback_start"
    case playbackSeek = "playback_seek"
    case playbackRoute = "playback_route"
    case playbackStop = "playback_stop"
}

enum DiagnosticsProvider: String, Codable, Sendable {
    case localFile = "local_file"
    case localLibrary = "local_library"
    case netease
    case qqmusic
    case kugou
    case amll
    case appleMusic = "apple_music"
    case systemNowPlaying = "system_now_playing"
    case musicbrainz
    case itunes
    case backend
    case unknown
}

private enum DiagnosticsAppMode: String, Codable {
    case local
    case appleMusic = "apple_music"
    case external
    case unknown
}

private enum DiagnosticsPlaybackMode: String, Codable {
    case local
    case appleMusic = "apple_music"
    case external
    case none
    case unknown
}

private enum DiagnosticsUIContext: String, Codable {
    case window
    case fullscreen
    case mini
    case settings
    case background
    case unknown
}

enum DiagnosticsContextValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        }
    }

    var fingerprintComponent: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        }
    }
}

typealias DiagnosticsContext = [String: DiagnosticsContextValue]

@MainActor
final class DiagnosticsService {
    static let shared = DiagnosticsService()

    private let consentKey = "telemetry.anonymousUsageEnabled"
    private let queue = DiagnosticsLocalQueue()
    private let uploader = DiagnosticsUploader()
    private weak var playbackCoordinator: PlaybackCoordinator?
    private var uploadTask: Task<Void, Never>?
    private var scheduledFlush: DispatchWorkItem?
    private var retryAfter: Date?
    private var consecutiveUploadFailures = 0

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: consentKey)
    }

    private init() {}

    func configure(playbackCoordinator: PlaybackCoordinator) {
        self.playbackCoordinator = playbackCoordinator
        if isEnabled {
            scheduleFlush(delay: 5)
        } else {
            queue.clear()
        }
    }

    func handleTelemetryConsentChanged(_ enabled: Bool) {
        if enabled {
            scheduleFlush(delay: 2)
        } else {
            uploadTask?.cancel()
            uploadTask = nil
            scheduledFlush?.cancel()
            scheduledFlush = nil
            retryAfter = nil
            consecutiveUploadFailures = 0
            queue.clear()
        }
    }

    nonisolated static func recordAsync(
        level: DiagnosticsLevel = .error,
        subsystem: DiagnosticsSubsystem,
        category: DiagnosticsCategory,
        stage: DiagnosticsStage,
        provider: DiagnosticsProvider? = nil,
        messageCode: String? = nil,
        context: DiagnosticsContext = [:]
    ) {
        Task { @MainActor in
            DiagnosticsService.shared.record(
                level: level,
                subsystem: subsystem,
                category: category,
                stage: stage,
                provider: provider,
                messageCode: messageCode,
                context: context
            )
        }
    }

    func record(
        level: DiagnosticsLevel = .error,
        subsystem: DiagnosticsSubsystem,
        category: DiagnosticsCategory,
        stage: DiagnosticsStage,
        provider: DiagnosticsProvider? = nil,
        messageCode: String? = nil,
        context: DiagnosticsContext = [:],
        occurredAt: Date = Date()
    ) {
        guard isEnabled else {
            queue.clear()
            return
        }

        let sanitizedContext = DiagnosticsSanitizer.sanitize(
            subsystem: subsystem,
            stage: stage,
            context: context
        )
        let safeMessageCode = DiagnosticsSanitizer.sanitizeCode(messageCode)
        let fingerprint = DiagnosticsFingerprint.make(
            subsystem: subsystem,
            category: category,
            stage: stage,
            provider: provider,
            messageCode: safeMessageCode,
            context: sanitizedContext
        )

        let event = DiagnosticsQueuedEvent(
            eventID: UUID().uuidString,
            occurredAt: occurredAt,
            installID: TelemetryService.shared.anonymousInstallID,
            schemaVersion: 1,
            level: level,
            subsystem: subsystem,
            category: category,
            stage: stage,
            provider: provider,
            fingerprint: fingerprint,
            messageCode: safeMessageCode,
            occurrenceCount: 1,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            arch: DiagnosticsRuntime.arch,
            appMode: currentAppMode(),
            playbackMode: currentPlaybackMode(),
            uiContext: currentUIContext(),
            isFullscreen: FullscreenWindowManager.shared.usesFullscreenPlayerUI,
            skinID: currentSkinID(),
            sanitizedContext: sanitizedContext
        )

        queue.enqueueOrMerge(event)
        scheduleFlush(delay: 3)
    }

    func flushQueue() {
        scheduledFlush?.cancel()
        scheduledFlush = nil

        guard isEnabled else {
            queue.clear()
            return
        }
        guard uploadTask == nil else { return }
        if let retryAfter, Date() < retryAfter { return }

        let events = Array(queue.pendingEvents().prefix(DiagnosticsLocalQueue.maxBatchEvents))
        guard !events.isEmpty else { return }

        uploadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await uploader.upload(events: events)
                try Task.checkCancellation()
                await MainActor.run {
                    self.applyUploadResponse(response, uploadedEvents: events)
                    self.consecutiveUploadFailures = 0
                    self.retryAfter = nil
                    self.uploadTask = nil
                    if !self.queue.pendingEvents().isEmpty {
                        self.scheduleFlush(delay: 1)
                    }
                }
            } catch {
                await MainActor.run {
                    self.consecutiveUploadFailures += 1
                    let delay = min(300, max(15, 15 * (1 << min(self.consecutiveUploadFailures - 1, 4))))
                    self.retryAfter = Date().addingTimeInterval(TimeInterval(delay))
                    self.uploadTask = nil
                    Log.warning("[Diagnostics] upload failed; retryAfter=\(delay)s code=\(DiagnosticsErrorMapper.code(for: error))", category: .telemetry)
                }
            }
        }
    }

    func flushSynchronouslyForTermination() {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        guard isEnabled else {
            queue.clear()
            return
        }

        let events = Array(queue.pendingEvents().prefix(DiagnosticsLocalQueue.maxBatchEvents))
        guard !events.isEmpty else { return }

        do {
            let response = try uploader.uploadSynchronously(events: events, timeout: 3)
            applyUploadResponse(response, uploadedEvents: events)
        } catch {
            Log.warning("[Diagnostics] termination upload failed code=\(DiagnosticsErrorMapper.code(for: error))", category: .telemetry)
        }
    }

    private func scheduleFlush(delay: TimeInterval) {
        guard isEnabled else { return }
        scheduledFlush?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.flushQueue()
            }
        }
        scheduledFlush = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func applyUploadResponse(
        _ response: DiagnosticsUploadResponse,
        uploadedEvents: [DiagnosticsQueuedEvent]
    ) {
        let completedIDs = response.acceptedEvents.map(\.eventID)
        queue.remove(eventIDs: completedIDs)
        for rejected in response.rejectedEvents where uploadedEvents.indices.contains(rejected.index) {
            queue.remove(eventIDs: [uploadedEvents[rejected.index].eventID])
        }
    }

    private func currentAppMode() -> DiagnosticsAppMode {
        guard let source = playbackCoordinator?.activeSource else { return .unknown }
        switch source {
        case .local: return .local
        case .appleMusic: return .appleMusic
        case .systemNowPlaying: return .external
        }
    }

    private func currentPlaybackMode() -> DiagnosticsPlaybackMode {
        guard let playbackCoordinator else { return .unknown }
        guard playbackCoordinator.presentation.isPlaying else { return .none }
        switch playbackCoordinator.activeSource {
        case .local: return .local
        case .appleMusic: return .appleMusic
        case .systemNowPlaying: return .external
        }
    }

    private func currentUIContext() -> DiagnosticsUIContext {
        if !NSApp.isActive {
            return .background
        }
        if FullscreenWindowManager.shared.usesFullscreenPlayerUI {
            return .fullscreen
        }
        return .window
    }

    private func currentSkinID() -> String? {
        let rawID = FullscreenWindowManager.shared.usesFullscreenPlayerUI
            ? SkinRegistry.fullscreenSkin(for: AppSettings.shared.fullscreen.skinID).id
            : SkinRegistry.skin(for: AppSettings.shared.selectedNowPlayingSkinID).id
        return DiagnosticsSanitizer.sanitizeCode(rawID)
    }
}

private struct DiagnosticsQueuedEvent: Codable, Equatable {
    var eventID: String
    var occurredAt: Date
    var installID: String
    var schemaVersion: Int
    var level: DiagnosticsLevel
    var subsystem: DiagnosticsSubsystem
    var category: DiagnosticsCategory
    var stage: DiagnosticsStage
    var provider: DiagnosticsProvider?
    var fingerprint: String
    var messageCode: String?
    var occurrenceCount: Int
    var appVersion: String
    var buildNumber: String?
    var osVersion: String
    var arch: String
    var appMode: DiagnosticsAppMode
    var playbackMode: DiagnosticsPlaybackMode
    var uiContext: DiagnosticsUIContext
    var isFullscreen: Bool
    var skinID: String?
    var sanitizedContext: DiagnosticsContext

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case occurredAt = "occurred_at"
        case installID = "install_id"
        case schemaVersion = "schema_version"
        case level
        case subsystem
        case category
        case stage
        case provider
        case fingerprint
        case messageCode = "message_code"
        case occurrenceCount = "occurrence_count"
        case appVersion = "app_version"
        case buildNumber = "build_number"
        case osVersion = "os_version"
        case arch
        case appMode = "app_mode"
        case playbackMode = "playback_mode"
        case uiContext = "ui_context"
        case isFullscreen = "is_fullscreen"
        case skinID = "skin_id"
        case sanitizedContext = "sanitized_context"
    }
}

private final class DiagnosticsLocalQueue {
    static let maxBatchEvents = 20
    private let maxEvents = 200
    private let mergeWindow: TimeInterval = 10 * 60
    private let fileURL = DiagnosticsFilePaths.applicationSupport
        .appendingPathComponent("diagnostics-queue.json")

    func enqueueOrMerge(_ event: DiagnosticsQueuedEvent) {
        var events = pendingEvents()
        if let index = events.lastIndex(where: {
            $0.fingerprint == event.fingerprint
                && abs(event.occurredAt.timeIntervalSince($0.occurredAt)) <= mergeWindow
        }) {
            events[index].occurrenceCount = min(events[index].occurrenceCount + 1, 10_000)
            events[index].occurredAt = event.occurredAt
            save(events)
            return
        }

        events.append(event)
        if events.count > maxEvents {
            events = Array(events.suffix(maxEvents))
        }
        save(events)
    }

    func pendingEvents() -> [DiagnosticsQueuedEvent] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DiagnosticsQueuedEvent].self, from: data)) ?? []
    }

    func remove(eventIDs: [String]) {
        let removed = Set(eventIDs)
        save(pendingEvents().filter { !removed.contains($0.eventID) })
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save(_ events: [DiagnosticsQueuedEvent]) {
        DiagnosticsFilePaths.ensureApplicationSupportExists()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(events) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

private enum DiagnosticsFilePaths {
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

private enum DiagnosticsSanitizer {
    private static let allowedContextKeys: Set<String> = [
        "operation", "http_status", "network_error_code", "response_parse_error_code",
        "duration_ms_bucket", "retry_count", "cache_hit", "result_count_bucket",
        "provider_rate_limited", "host_type",
        "source_type", "file_extension", "file_size_bucket", "is_ncm", "audio_container",
        "codec_hint", "import_stage", "error_code", "has_title", "has_artist", "has_album",
        "has_embedded_artwork", "copy_target", "rollback_performed",
        "ncm_stage", "output_extension", "fallback_used",
        "lyrics_source", "lyrics_format", "parse_error_code", "line_count_bucket",
        "has_translation", "has_romanization", "conversion_path",
        "artwork_source", "image_format", "image_size_bucket", "decode_error_code",
        "amll_stage", "webview_state", "js_error_type", "line_number_bucket",
        "amll_bundle_version", "webcontent_terminated_reason", "reload_count",
        "ui_context", "is_fullscreen", "skin_id",
        "playback_engine", "duration_bucket", "is_stream", "route_type",
        "seek_position_bucket", "asset_load_stage",
        "permission_state", "connection_state",
        "update_channel", "endpoint_type", "current_build_number",
        "latest_build_number_present", "download_url_present"
    ]

    private static let codePattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9._:-]+$"#)

    static func sanitize(
        subsystem: DiagnosticsSubsystem,
        stage: DiagnosticsStage,
        context: DiagnosticsContext
    ) -> DiagnosticsContext {
        var sanitized: DiagnosticsContext = [:]
        for key in context.keys.sorted() {
            guard allowedContextKeys.contains(key), let value = context[key] else { continue }
            switch value {
            case .string(let raw):
                guard let safe = sanitizeCode(raw) else { continue }
                sanitized[key] = .string(safe)
            case .int(let raw):
                sanitized[key] = .int(max(-1_000_000, min(10_000_000, raw)))
            case .bool(let raw):
                sanitized[key] = .bool(raw)
            }
        }
        return trimToContextLimit(sanitized)
    }

    static func sanitizeCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else { return nil }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        guard codePattern.firstMatch(in: trimmed, range: range)?.range == range else {
            return nil
        }
        return trimmed
    }

    private static func trimToContextLimit(_ context: DiagnosticsContext) -> DiagnosticsContext {
        var copy = context
        let encoder = JSONEncoder()
        while let data = try? encoder.encode(copy), data.count > 4096, !copy.isEmpty {
            if let lastKey = copy.keys.sorted().last {
                copy.removeValue(forKey: lastKey)
            } else {
                break
            }
        }
        return copy
    }
}

private enum DiagnosticsFingerprint {
    static func make(
        subsystem: DiagnosticsSubsystem,
        category: DiagnosticsCategory,
        stage: DiagnosticsStage,
        provider: DiagnosticsProvider?,
        messageCode: String?,
        context: DiagnosticsContext
    ) -> String {
        var parts = [
            subsystem.rawValue,
            category.rawValue,
            stage.rawValue,
            provider?.rawValue ?? "",
            messageCode ?? ""
        ]
        for key in context.keys.sorted() {
            if let value = context[key] {
                parts.append("\(key)=\(value.fingerprintComponent)")
            }
        }
        let digest = SHA256.hash(data: parts.joined(separator: "|").data(using: .utf8) ?? Data())
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

private struct DiagnosticsUploadRequest: Codable {
    let client: DiagnosticsUploadClient
    let events: [DiagnosticsQueuedEvent]
}

private struct DiagnosticsUploadClient: Codable {
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

private struct DiagnosticsUploadResponse: Decodable {
    let success: Bool
    let acceptedCount: Int
    let duplicateCount: Int
    let rejectedCount: Int
    let acceptedEvents: [DiagnosticsAcceptedEvent]
    let rejectedEvents: [DiagnosticsRejectedEvent]

    enum CodingKeys: String, CodingKey {
        case success
        case acceptedCount = "accepted_count"
        case duplicateCount = "duplicate_count"
        case rejectedCount = "rejected_count"
        case acceptedEvents = "accepted_events"
        case rejectedEvents = "rejected_events"
    }
}

private struct DiagnosticsAcceptedEvent: Decodable {
    let eventID: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case status
    }
}

private struct DiagnosticsRejectedEvent: Decodable {
    let index: Int
    let reason: String
}

private final class DiagnosticsUploader {
    private let endpoint = URL(string: "https://player.kmgccc.cn/api/v1/diagnostics/events/batch")!
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration)
    }

    func upload(events: [DiagnosticsQueuedEvent]) async throws -> DiagnosticsUploadResponse {
        let request = try makeRequest(events: events, timeout: 5)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(DiagnosticsUploadResponse.self, from: data)
    }

    func uploadSynchronously(events: [DiagnosticsQueuedEvent], timeout: TimeInterval) throws -> DiagnosticsUploadResponse {
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
        return try JSONDecoder().decode(DiagnosticsUploadResponse.self, from: receivedData)
    }

    private func makeRequest(events: [DiagnosticsQueuedEvent], timeout: TimeInterval) throws -> URLRequest {
        guard let first = events.first else { throw URLError(.badURL) }
        let body = DiagnosticsUploadRequest(
            client: DiagnosticsUploadClient(
                appVersion: first.appVersion,
                buildNumber: first.buildNumber,
                platform: "macOS",
                schemaVersion: 1
            ),
            events: events
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return request
    }
}

nonisolated enum DiagnosticsBuckets {
    static func durationMs(_ milliseconds: Double) -> String {
        if milliseconds < 500 { return "lt_500ms" }
        if milliseconds < 2_000 { return "500ms_2s" }
        if milliseconds < 5_000 { return "2s_5s" }
        if milliseconds < 10_000 { return "5s_10s" }
        return "gt_10s"
    }

    static func fileSize(for url: URL) -> String {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return "unknown"
        }
        return fileSize(bytes: size.int64Value)
    }

    static func fileSize(bytes: Int64) -> String {
        let mb = Double(max(0, bytes)) / 1_048_576
        if mb < 5 { return "lt_5mb" }
        if mb < 10 { return "5_10mb" }
        if mb < 50 { return "10_50mb" }
        if mb < 200 { return "50_200mb" }
        return "gt_200mb"
    }

    static func resultCount(_ count: Int) -> String {
        if count <= 0 { return "0" }
        if count == 1 { return "1" }
        if count <= 5 { return "2_5" }
        if count <= 20 { return "6_20" }
        return "gt_20"
    }

    static func lineCount(_ count: Int) -> String {
        if count <= 0 { return "0" }
        if count <= 20 { return "1_20" }
        if count <= 100 { return "21_100" }
        if count <= 300 { return "101_300" }
        return "gt_300"
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "unknown" }
        if seconds < 60 { return "lt_1min" }
        if seconds < 180 { return "1_3min" }
        if seconds < 300 { return "3_5min" }
        if seconds < 600 { return "5_10min" }
        return "gt_10min"
    }

    static func seekPosition(position: Double, duration: Double) -> String {
        guard position.isFinite, duration.isFinite, duration > 0 else { return "unknown" }
        let ratio = max(0, min(1, position / duration))
        if ratio < 0.1 { return "start" }
        if ratio > 0.9 { return "end" }
        return "middle"
    }

    static func imageSize(width: Int, height: Int) -> String {
        let edge = max(width, height)
        if edge <= 0 { return "unknown" }
        if edge < 600 { return "small" }
        if edge < 1_400 { return "medium" }
        if edge < 3_000 { return "large" }
        return "huge"
    }
}

nonisolated enum DiagnosticsSafeContext {
    static func fileExtension(from url: URL?) -> String {
        fileExtension(from: url?.pathExtension)
    }

    static func fileExtension(from raw: String?) -> String {
        let ext = raw?.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted) ?? ""
        switch ext {
        case "mp3", "flac", "m4a", "mp4", "ncm", "wav", "aiff", "aif", "aac":
            return ext == "aif" ? "aiff" : ext
        default:
            return "unknown"
        }
    }

    static func audioContainer(for fileExtension: String) -> String {
        switch fileExtension {
        case "mp3": return "mp3"
        case "flac": return "flac"
        case "m4a", "mp4", "aac": return "mp4"
        case "wav": return "wav"
        case "aiff": return "aiff"
        default: return "unknown"
        }
    }

    static func codecHint(for fileExtension: String) -> String {
        switch fileExtension {
        case "mp3": return "mp3"
        case "flac": return "flac"
        case "m4a", "mp4", "aac": return "aac"
        case "wav", "aiff": return "pcm"
        default: return "unknown"
        }
    }

    static func imageFormat(from data: Data?) -> String {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else {
            return "unknown"
        }
        if type.contains("jpeg") { return "jpg" }
        if type.contains("png") { return "png" }
        if type.contains("webp") { return "webp" }
        if type.contains("heic") || type.contains("heif") { return "heic" }
        return "unknown"
    }

    static func imageSizeBucket(from data: Data?) -> String {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return "unknown"
        }
        return DiagnosticsBuckets.imageSize(width: width, height: height)
    }

    static func bool(_ value: Bool?) -> DiagnosticsContextValue {
        guard let value else { return .string("unknown") }
        return .bool(value)
    }
}

nonisolated enum DiagnosticsErrorMapper {
    static func code(for error: Error) -> String {
        if let ncmError = error as? NCMConverterError {
            return ncmCode(for: ncmError)
        }
        if let lddcError = error as? LDDCError {
            return lddcCode(for: lddcError)
        }
        if let coverError = error as? CoverDownloadError {
            return coverCode(for: coverError)
        }
        if let neteaseError = error as? NetEaseCoverError {
            return neteaseCode(for: neteaseError)
        }
        if let qqMusicError = error as? QQMusicCoverError {
            return qqMusicCoverCode(for: qqMusicError)
        }
        if let timeout = error as? CoverLookupTimeoutError {
            switch timeout {
            case .timedOut:
                return "timeout"
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return urlCode(for: URLError.Code(rawValue: nsError.code))
        }
        if nsError.domain == NSCocoaErrorDomain {
            return "cocoa_\(nsError.code)"
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return "posix_\(nsError.code)"
        }
        return "unknown_error"
    }

    static func urlCode(for code: URLError.Code) -> String {
        switch code {
        case .timedOut: return "url_timed_out"
        case .notConnectedToInternet: return "url_not_connected"
        case .cannotFindHost: return "url_cannot_find_host"
        case .cannotConnectToHost: return "url_cannot_connect"
        case .networkConnectionLost: return "url_connection_lost"
        case .badServerResponse: return "url_bad_server_response"
        case .cancelled: return "url_cancelled"
        default: return "url_\(code.rawValue)"
        }
    }

    static func ncmCode(for error: NCMConverterError) -> String {
        switch error {
        case .invalidFile: return "ncm_invalid_file"
        case .invalidMagic: return "ncm_invalid_magic"
        case .decryptionFailed: return "ncm_decryption_failed"
        case .keyDecryptionFailed: return "ncm_key_decryption_failed"
        case .metadataDecryptionFailed: return "ncm_metadata_decryption_failed"
        case .unsupportedFormat: return "ncm_unsupported_format"
        case .fileReadError: return "ncm_file_read_error"
        case .fileWriteError: return "ncm_file_write_error"
        case .networkError: return "ncm_network_error"
        case .invalidMetadata: return "ncm_invalid_metadata"
        }
    }

    static func ncmStage(for error: Error) -> String {
        guard let error = error as? NCMConverterError else { return "unknown" }
        switch error {
        case .invalidFile, .invalidMagic, .fileReadError:
            return "header_parse"
        case .keyDecryptionFailed:
            return "key_decrypt"
        case .metadataDecryptionFailed, .invalidMetadata:
            return "metadata_parse"
        case .decryptionFailed, .unsupportedFormat:
            return "audio_extract"
        case .fileWriteError:
            return "write_output"
        case .networkError:
            return "audio_extract"
        }
    }

    static func lddcCode(for error: LDDCError) -> String {
        switch error {
        case .serverNotRunning: return "lddc_server_not_running"
        case .healthCheckFailed: return "lddc_health_check_failed"
        case .startupFailed: return "lddc_startup_failed"
        case .portUnavailable: return "lddc_port_unavailable"
        case .requestFailed: return "lddc_request_failed"
        case .noResults: return "lddc_no_results"
        case .invalidResponse: return "lddc_invalid_response"
        }
    }

    static func coverCode(for error: CoverDownloadError) -> String {
        switch error {
        case .executableMissing: return "sacad_executable_missing"
        case .processFailed: return "sacad_process_failed"
        case .outputMissing: return "sacad_output_missing"
        case .invalidImageData: return "invalid_image_data"
        case .cancelled: return "cancelled"
        }
    }

    static func neteaseCode(for error: NetEaseCoverError) -> String {
        switch error {
        case .badURL: return "netease_bad_url"
        case .requestFailed(let underlying): return code(for: underlying)
        case .decodingFailed: return "netease_decode_failed"
        case .noResults: return "no_results"
        case .imageDownloadFailed(let underlying): return code(for: underlying)
        }
    }

    static func qqMusicCoverCode(for error: QQMusicCoverError) -> String {
        switch error {
        case .badURL: return "qqmusic_bad_url"
        case .noResults: return "qqmusic_no_results"
        case .imageDownloadFailed: return "qqmusic_image_download_failed"
        }
    }
}

private enum DiagnosticsRuntime {
    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
