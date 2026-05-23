//
//  Log.swift
//  myPlayer2
//
//  kmgccc_player - Unified Logging System
//  Thread-safe and callable from any context without await.
//

import CoreGraphics
import Foundation
import OSLog

// MARK: - Log Category

enum LogCategory: String, CaseIterable, Sendable {
    case audio = "audio"
    case `import` = "import"
    case library = "library"
    case lyrics = "lyrics"
    case theme = "theme"
    case fullscreen = "fullscreen"
    case perf = "perf"
    case webview = "webview"
    case lddc = "lddc"
    case ui = "ui"
    case playback = "playback"
    case telemetry = "telemetry"
    case file = "file"
    case general = "general"
}

// MARK: - Log Level

enum LogLevel: Int, Sendable {
    case error = 0
    case warning = 1
    case info = 2
    case debug = 3
    case trace = 4
    
    nonisolated static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    nonisolated var osLogType: OSLogType {
        switch self {
        case .error: return .error
        case .warning: return .default
        case .info: return .info
        case .debug, .trace: return .debug
        }
    }
    
    nonisolated var emoji: String {
        switch self {
        case .error: return "❌"
        case .warning: return "⚠️"
        case .info: return "ℹ️"
        case .debug: return "🔍"
        case .trace: return "·"
        }
    }
}

// MARK: - Log Configuration Storage

private nonisolated(unsafe) var _logConfigLock = NSLock()
private nonisolated(unsafe) var _logDebugEnabledCategories: Set<LogCategory> = []

enum LogConfig {
    
    nonisolated static var minimumLevel: LogLevel {
        #if DEBUG
        return .info
        #else
        return .warning
        #endif
    }
    
    nonisolated static var debugEnabledCategories: Set<LogCategory> {
        _logConfigLock.lock()
        defer { _logConfigLock.unlock() }
        return _logDebugEnabledCategories
    }
    
    nonisolated static var printToConsole: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    
    nonisolated static func enableDebug(for categories: LogCategory...) {
        _logConfigLock.lock()
        defer { _logConfigLock.unlock() }
        _logDebugEnabledCategories.formUnion(categories)
    }
    
    nonisolated static func enableTrace(for categories: LogCategory...) {
        _logConfigLock.lock()
        defer { _logConfigLock.unlock() }
        _logDebugEnabledCategories.formUnion(categories)
    }
    
    nonisolated static func disableDebug(for categories: LogCategory...) {
        _logConfigLock.lock()
        defer { _logConfigLock.unlock() }
        for cat in categories {
            _logDebugEnabledCategories.remove(cat)
        }
    }
    
    nonisolated static func resetDebugCategories() {
        _logConfigLock.lock()
        defer { _logConfigLock.unlock() }
        _logDebugEnabledCategories.removeAll()
    }
    
    nonisolated static func isCategoryEnabled(_ category: LogCategory) -> Bool {
        _logConfigLock.lock()
        defer { _logConfigLock.unlock() }
        return _logDebugEnabledCategories.contains(category)
    }
}

// MARK: - Logger Cache

private nonisolated(unsafe) var _loggerCache: [LogCategory: Logger] = [:]
private nonisolated(unsafe) var _loggerCacheLock = NSLock()

nonisolated private func _getLogger(for category: LogCategory) -> Logger {
    _loggerCacheLock.lock()
    defer { _loggerCacheLock.unlock() }
    
    if let cached = _loggerCache[category] {
        return cached
    }
    
    let newLogger = Logger(subsystem: "kmg.myplayer2", category: category.rawValue)
    _loggerCache[category] = newLogger
    return newLogger
}

// MARK: - Log

enum Log {
    
    nonisolated static func error(
        _ message: @autoclosure () -> String,
        category: LogCategory,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        _log(level: .error, message: message(), category: category)
    }
    
    nonisolated static func warning(
        _ message: @autoclosure () -> String,
        category: LogCategory,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        _log(level: .warning, message: message(), category: category)
    }
    
    nonisolated static func info(
        _ message: @autoclosure () -> String,
        category: LogCategory,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        _log(level: .info, message: message(), category: category)
    }
    
    nonisolated static func debug(
        _ message: @autoclosure () -> String,
        category: LogCategory,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        _log(level: .debug, message: message(), category: category)
    }
    
    nonisolated static func trace(
        _ message: @autoclosure () -> String,
        category: LogCategory,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        _log(level: .trace, message: message(), category: category)
    }
    
    nonisolated static func playback(
        _ message: @autoclosure () -> String,
        level: LogLevel = .info
    ) {
        switch level {
        case .error: error(message(), category: .playback)
        case .warning: warning(message(), category: .playback)
        case .info: info(message(), category: .playback)
        case .debug: debug(message(), category: .playback)
        case .trace: trace(message(), category: .playback)
        }
    }
}

// MARK: - Internal Log Function

nonisolated private func _log(
    level: LogLevel,
    message: String,
    category: LogCategory
) {
    guard level.rawValue <= LogConfig.minimumLevel.rawValue else { return }
    
    if level.rawValue >= LogLevel.debug.rawValue {
        guard LogConfig.isCategoryEnabled(category) else { return }
    }
    
    let logger = _getLogger(for: category)
    
    switch level {
    case .error:
        logger.error("\(message)")
    case .warning:
        logger.warning("\(message)")
    case .info:
        logger.info("\(message)")
    case .debug, .trace:
        logger.debug("\(message)")
    }
    
    if LogConfig.printToConsole {
        let prefix = "\(level.emoji)[\(category.rawValue)]"
        print("\(prefix) \(message)")
    }
}

// MARK: - Logger Extension for Warning

extension Logger {
    nonisolated func warning(_ message: String) {
        log("\(message)")
    }
}

// MARK: - First-use Hitch Diagnostics

nonisolated struct FirstUseHitchToken: Sendable {
    let id: UUID
    let key: String
    let occurrence: Int
    let startedAtUptime: TimeInterval

    var phase: String {
        occurrence == 1 ? "cold" : "warm"
    }
}

nonisolated enum FirstUseHitchDiagnostics {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var countsByKey: [String: Int] = [:]
    private nonisolated(unsafe) static var activeMainOperationID: UUID?
    private nonisolated(unsafe) static var activeMainOperationDescription: String?
    private nonisolated(unsafe) static var signpostStates: [UUID: OSSignpostIntervalState] = [:]
    private static let signposter = OSSignposter(
        subsystem: "kmg.myplayer2",
        category: "first_use_hitch"
    )

    nonisolated static func begin(_ key: String, detail: String? = nil) -> FirstUseHitchToken {
        let id = UUID()
        let occurrence: Int
        let state = signposter.beginInterval("FirstUseHitch", id: signposter.makeSignpostID())

        lock.lock()
        occurrence = (countsByKey[key] ?? 0) + 1
        countsByKey[key] = occurrence
        signpostStates[id] = state
        if Thread.isMainThread {
            activeMainOperationID = id
            activeMainOperationDescription = operationDescription(
                key: key,
                occurrence: occurrence,
                detail: detail
            )
        }
        lock.unlock()

        Log.info(
            "[FirstUseHitch] begin key=\(key) phase=\(occurrence == 1 ? "cold" : "warm") occurrence=\(occurrence) thread=\(Thread.isMainThread ? "main" : "background")\(detail.map { " detail=\($0)" } ?? "")",
            category: .perf
        )

        return FirstUseHitchToken(
            id: id,
            key: key,
            occurrence: occurrence,
            startedAtUptime: ProcessInfo.processInfo.systemUptime
        )
    }

    nonisolated static func end(_ token: FirstUseHitchToken, detail: String? = nil) {
        let durationMs = (ProcessInfo.processInfo.systemUptime - token.startedAtUptime) * 1000
        let state: OSSignpostIntervalState?

        lock.lock()
        state = signpostStates.removeValue(forKey: token.id)
        if activeMainOperationID == token.id {
            activeMainOperationID = nil
            activeMainOperationDescription = nil
        }
        lock.unlock()

        if let state {
            signposter.endInterval("FirstUseHitch", state)
        }

        Log.info(
            "[FirstUseHitch] end key=\(token.key) phase=\(token.phase) occurrence=\(token.occurrence) durationMs=\(String(format: "%.1f", durationMs))\(detail.map { " detail=\($0)" } ?? "")",
            category: .perf
        )
    }

    nonisolated static func currentMainOperationDescription() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return activeMainOperationDescription
    }

    @discardableResult
    nonisolated static func measure<T>(_ key: String, detail: String? = nil, _ body: () throws -> T) rethrows -> T {
        let token = begin(key, detail: detail)
        defer { end(token) }
        return try body()
    }

    private nonisolated static func operationDescription(
        key: String,
        occurrence: Int,
        detail: String?
    ) -> String {
        "\(key)#\(occurrence == 1 ? "cold" : "warm")\(detail.map { ":\($0)" } ?? "")"
    }
}

// MARK: - Runtime Lyrics Profiling

nonisolated private struct LyricsRuntimeProfileSession {
    let id: Int
    let trigger: String
    let selection: String
    let hasHeader: Bool
    let contentMode: String
    let trackID: String
    let trackTitle: String
    let startedAtUptime: TimeInterval
    var counters: [String: Int] = [:]
    var durationsMs: [String: Double] = [:]
    var timepointsMs: [String: Double] = [:]
    var metadata: [String: String] = [:]
    var uniqueValues: [String: Set<String>] = [:]
    var jsProfile: [String: Any]?
}

nonisolated enum LyricsRuntimeProfile {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var nextSessionID = 0
    private nonisolated(unsafe) static var currentSession: LyricsRuntimeProfileSession?
    private nonisolated(unsafe) static var finalizeWorkItem: DispatchWorkItem?

    nonisolated static let enabled: Bool = {
        let rawValue = ProcessInfo.processInfo.environment["KMGCCC_LYRICS_RUNTIME_PROFILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return rawValue == "1" || rawValue == "true" || rawValue == "yes" || rawValue == "on"
    }()

    @discardableResult
    nonisolated static func markBody(_ key: String) -> Int {
        guard enabled else { return 0 }
        increment(key)
        return 0
    }

    @discardableResult
    nonisolated static func beginSession(
        trigger: String,
        selection: String,
        hasHeader: Bool,
        contentMode: String,
        trackID: UUID?,
        trackTitle: String?
    ) -> Int? {
        guard enabled else { return nil }

        lock.lock()
        defer { lock.unlock() }

        if let existing = currentSession {
            emitLocked(existing, reason: "superseded")
            currentSession = nil
        }
        finalizeWorkItem?.cancel()
        finalizeWorkItem = nil

        nextSessionID += 1
        let session = LyricsRuntimeProfileSession(
            id: nextSessionID,
            trigger: trigger,
            selection: selection,
            hasHeader: hasHeader,
            contentMode: contentMode,
            trackID: trackID?.uuidString ?? "nil",
            trackTitle: trackTitle ?? "nil",
            startedAtUptime: ProcessInfo.processInfo.systemUptime
        )
        currentSession = session

        scheduleAutoFinalizeLocked(sessionID: session.id, after: 1.35)
        return session.id
    }

    nonisolated static func currentSessionID() -> Int? {
        guard enabled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return currentSession?.id
    }

    nonisolated static func increment(_ key: String, by delta: Int = 1) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var session = currentSession else { return }
        session.counters[key, default: 0] += delta
        currentSession = session
    }

    nonisolated static func addDuration(_ key: String, ms: Double) {
        guard enabled else { return }
        guard ms.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var session = currentSession else { return }
        session.durationsMs[key, default: 0] += ms
        currentSession = session
    }

    nonisolated static func recordTimepoint(_ key: String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var session = currentSession else { return }
        guard session.timepointsMs[key] == nil else { return }
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - session.startedAtUptime) * 1000
        guard elapsedMs.isFinite else { return }
        session.timepointsMs[key] = elapsedMs
        currentSession = session
    }

    nonisolated static func setMetadata(_ key: String, value: String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var session = currentSession else { return }
        session.metadata[key] = value
        currentSession = session
    }

    nonisolated static func insertUniqueValue(_ key: String, value: String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var session = currentSession else { return }
        var values = session.uniqueValues[key, default: []]
        values.insert(value)
        session.uniqueValues[key] = values
        currentSession = session
    }

    nonisolated static func recordFrameWrite(
        key: String,
        previous: CGRect,
        next: CGRect
    ) {
        guard enabled else { return }
        increment("\(key).count")
        if nearlyEqual(previous: previous, next: next) {
            increment("\(key).same")
        } else {
            increment("\(key).changed")
            setMetadata("\(key).last", value: formatRect(next))
        }
    }

    nonisolated static func recordFlagChange(
        key: String,
        previous: Bool,
        next: Bool
    ) {
        guard enabled else { return }
        increment("\(key).count")
        if previous == next {
            increment("\(key).same")
        } else {
            increment("\(key).changed")
            setMetadata("\(key).last", value: next ? "true" : "false")
        }
    }

    nonisolated static func mergeJSProfile(
        sessionID: Int,
        payload: [String: Any]
    ) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var session = currentSession, session.id == sessionID else { return }
        session.jsProfile = payload
        currentSession = session
    }

    nonisolated static func finalizeSession(
        sessionID: Int? = nil,
        reason: String
    ) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let session = currentSession else { return }
        if let sessionID, session.id != sessionID {
            return
        }
        finalizeWorkItem?.cancel()
        finalizeWorkItem = nil
        emitLocked(session, reason: reason)
        currentSession = nil
    }

    private nonisolated static func scheduleAutoFinalizeLocked(sessionID: Int, after delay: TimeInterval) {
        let workItem = DispatchWorkItem {
            LyricsRuntimeProfile.finalizeSession(sessionID: sessionID, reason: "auto-timeout")
        }
        finalizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private nonisolated static func emitLocked(_ session: LyricsRuntimeProfileSession, reason: String) {
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - session.startedAtUptime) * 1000
        var payload: [String: Any] = [
            "sessionID": session.id,
            "reason": reason,
            "trigger": session.trigger,
            "selection": session.selection,
            "hasHeader": session.hasHeader,
            "contentMode": session.contentMode,
            "trackID": session.trackID,
            "trackTitle": session.trackTitle,
            "elapsedMs": round(elapsedMs * 100) / 100,
            "counters": session.counters,
            "durationsMs": roundedDictionary(session.durationsMs),
            "metadata": session.metadata,
        ]
        if !session.timepointsMs.isEmpty {
            payload["timepointsMs"] = roundedDictionary(session.timepointsMs)
        }
        if !session.uniqueValues.isEmpty {
            payload["uniqueCounts"] = session.uniqueValues.mapValues(\.count)
        }
        if let jsProfile = session.jsProfile {
            payload["jsProfile"] = jsProfile
        }

        Log.info(
            "[LyricsRuntimeProfile][Summary] \(compactJSONString(payload))",
            category: .perf
        )
    }

    private nonisolated static func roundedDictionary(_ source: [String: Double]) -> [String: Double] {
        var result: [String: Double] = [:]
        for (key, value) in source {
            result[key] = round(value * 100) / 100
        }
        return result
    }

    private nonisolated static func compactJSONString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: object)
        }
        return string
    }

    private nonisolated static func nearlyEqual(previous: CGRect, next: CGRect) -> Bool {
        abs(previous.origin.x - next.origin.x) < 0.5
            && abs(previous.origin.y - next.origin.y) < 0.5
            && abs(previous.size.width - next.size.width) < 0.5
            && abs(previous.size.height - next.size.height) < 0.5
    }

    private nonisolated static func formatRect(_ rect: CGRect) -> String {
        "x=\(Int(rect.origin.x.rounded())) y=\(Int(rect.origin.y.rounded())) w=\(Int(rect.size.width.rounded())) h=\(Int(rect.size.height.rounded()))"
    }
}

nonisolated enum TintTimelineProbe {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var sessionID: Int?
    private nonisolated(unsafe) static var rootReceiveIndex = 0
    private nonisolated(unsafe) static var headerPublishIndex = 0
    private nonisolated(unsafe) static var rootCommitIndex = 0
    private nonisolated(unsafe) static var lastHeaderConsumerIndex: [String: Int] = [:]
    private nonisolated(unsafe) static var lastRootConsumerIndex: [String: Int] = [:]

    nonisolated static func noteRootReceive(source: String) {
        guard LyricsRuntimeProfile.enabled else { return }
        guard let currentSessionID = LyricsRuntimeProfile.currentSessionID() else { return }
        lock.lock()
        resetIfNeeded(for: currentSessionID)
        rootReceiveIndex += 1
        let index = rootReceiveIndex
        lock.unlock()

        LyricsRuntimeProfile.increment("tint.root.receive.count")
        LyricsRuntimeProfile.recordTimepoint("tint.root.receive.\(index)")
        LyricsRuntimeProfile.setMetadata("tint.root.receive.\(index).source", value: source)
    }

    nonisolated static func noteHeaderPublish(source: String) {
        guard LyricsRuntimeProfile.enabled else { return }
        guard let currentSessionID = LyricsRuntimeProfile.currentSessionID() else { return }
        lock.lock()
        resetIfNeeded(for: currentSessionID)
        headerPublishIndex += 1
        let index = headerPublishIndex
        lock.unlock()

        LyricsRuntimeProfile.increment("tint.header.publish.count")
        LyricsRuntimeProfile.recordTimepoint("tint.header.publish.\(index)")
        LyricsRuntimeProfile.setMetadata("tint.header.publish.\(index).source", value: source)
    }

    nonisolated static func noteRootCommit(source: String) {
        guard LyricsRuntimeProfile.enabled else { return }
        guard let currentSessionID = LyricsRuntimeProfile.currentSessionID() else { return }
        lock.lock()
        resetIfNeeded(for: currentSessionID)
        rootCommitIndex += 1
        let index = rootCommitIndex
        lock.unlock()

        LyricsRuntimeProfile.increment("tint.root.commit.count")
        LyricsRuntimeProfile.recordTimepoint("tint.root.commit.\(index)")
        LyricsRuntimeProfile.setMetadata("tint.root.commit.\(index).source", value: source)
    }

    nonisolated static func noteHeaderConsumer(_ key: String) {
        guard LyricsRuntimeProfile.enabled else { return }
        guard let currentSessionID = LyricsRuntimeProfile.currentSessionID() else { return }
        lock.lock()
        resetIfNeeded(for: currentSessionID)
        guard headerPublishIndex > 0 else {
            lock.unlock()
            return
        }
        let sanitizedKey = sanitize(key)
        guard lastHeaderConsumerIndex[sanitizedKey] != headerPublishIndex else {
            lock.unlock()
            return
        }
        lastHeaderConsumerIndex[sanitizedKey] = headerPublishIndex
        let index = headerPublishIndex
        lock.unlock()

        LyricsRuntimeProfile.increment("tint.header.consumer.count")
        LyricsRuntimeProfile.recordTimepoint("tint.header.consumer.\(sanitizedKey).\(index)")
    }

    nonisolated static func noteRootConsumer(_ key: String) {
        guard LyricsRuntimeProfile.enabled else { return }
        guard let currentSessionID = LyricsRuntimeProfile.currentSessionID() else { return }
        lock.lock()
        resetIfNeeded(for: currentSessionID)
        guard rootCommitIndex > 0 else {
            lock.unlock()
            return
        }
        let sanitizedKey = sanitize(key)
        guard lastRootConsumerIndex[sanitizedKey] != rootCommitIndex else {
            lock.unlock()
            return
        }
        lastRootConsumerIndex[sanitizedKey] = rootCommitIndex
        let index = rootCommitIndex
        lock.unlock()

        LyricsRuntimeProfile.increment("tint.root.consumer.count")
        LyricsRuntimeProfile.recordTimepoint("tint.root.consumer.\(sanitizedKey).\(index)")
    }

    private nonisolated static func resetIfNeeded(for currentSessionID: Int) {
        guard sessionID != currentSessionID else { return }
        sessionID = currentSessionID
        rootReceiveIndex = 0
        headerPublishIndex = 0
        rootCommitIndex = 0
        lastHeaderConsumerIndex = [:]
        lastRootConsumerIndex = [:]
    }

    private nonisolated static func sanitize(_ value: String) -> String {
        String(
            value.map { character in
                character.isLetter || character.isNumber ? character : "_"
            }
        )
    }
}
