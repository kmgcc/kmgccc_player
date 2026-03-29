//
//  Log.swift
//  myPlayer2
//
//  kmgccc_player - Unified Logging System
//  Thread-safe and callable from any context without await.
//

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
