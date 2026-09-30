//
//  LyricsDebugFlags.swift
//  myPlayer2
//
//  Debug flags for the native window lyrics performance investigation.
//

import Foundation

enum LyricsDebugFlags {
    /// Use the flat AppKit lyrics host instead of the SwiftUI inspector host.
    /// Disable only when comparing the two native host paths.
    static var windowUseFlatAppKitHost: Bool {
        let key = "lyrics.debug.windowUseFlatAppKitHost"
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }
}

/// Opt-in DEBUG traces for the fullscreen player / lyrics surface lifecycle.
/// These diagnostic timing traces are silent by default. Enable with
/// KMGCCC_FS_DIAGNOSTICS=1 at launch. In release builds every entry point is
/// a no-op.
enum FSDiagnostics {
    #if DEBUG
    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["KMGCCC_FS_DIAGNOSTICS"] == "1"
    }

    nonisolated static func emit(
        _ message: @autoclosure () -> String,
        category: LogCategory
    ) {
        guard isEnabled else { return }
        Log.warning("[FS-DIAG] \(message())", category: category)
    }
    #else
    nonisolated static let isEnabled = false
    nonisolated static func emit(_ message: @autoclosure () -> String, category: LogCategory) {}
    #endif
}
