import Foundation

enum LogCategory: String, Sendable {
    case theme
    case ui
}

enum LogConfig {
    nonisolated static func isCategoryEnabled(_ category: LogCategory) -> Bool {
        false
    }
}

enum Log {
    nonisolated static func warning(
        _ message: @autoclosure () -> String,
        category: LogCategory,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        // No-op shim for the standalone Golden Master CLI.
    }

    nonisolated static func debug(
        _ message: @autoclosure () -> String,
        category: LogCategory,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        // No-op shim for the standalone Golden Master CLI.
    }

    nonisolated static func trace(
        _ message: @autoclosure () -> String,
        category: LogCategory,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        // No-op shim for the standalone Golden Master CLI.
    }
}
