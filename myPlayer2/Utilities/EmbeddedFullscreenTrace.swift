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

