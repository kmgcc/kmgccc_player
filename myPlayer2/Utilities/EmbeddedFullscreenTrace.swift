//
//  EmbeddedFullscreenTrace.swift
//  myPlayer2
//
//  Debug-only trace helper for diagnosing embedded/windowed fullscreen viewport settle issues.
//  Enabled via env var: KMGCCC_EMBEDDED_FULLSCREEN_TRACE=1
//

import Foundation

enum EmbeddedFullscreenTrace {
    nonisolated static let enabled: Bool = {
        let env = ProcessInfo.processInfo.environment["KMGCCC_EMBEDDED_FULLSCREEN_TRACE"] ?? ""
        return ["1", "true", "yes", "on"].contains(env.lowercased())
    }()

    nonisolated static func stamp() -> String {
        String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
    }
}

enum PaneLayoutTrace {
    nonisolated static let enabled: Bool = {
        let env = ProcessInfo.processInfo.environment["KMGCCC_PANE_LAYOUT_TRACE"] ?? ""
        return EmbeddedFullscreenTrace.enabled
            || ["1", "true", "yes", "on"].contains(env.lowercased())
    }()

    nonisolated static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        Log.info("[PaneLayout t=\(EmbeddedFullscreenTrace.stamp())] \(message())", category: .ui)
    }

    nonisolated static func callerSummary(skip: Int = 2, limit: Int = 5) -> String {
        guard enabled else { return "" }
        return Thread.callStackSymbols
            .dropFirst(skip)
            .prefix(limit)
            .map { symbol in
                symbol
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .joined(separator: " <- ")
    }
}
