//
//  StubLyricsBridgeService.swift
//  myPlayer2
//
//  kmgccc_player - Stub Lyrics Bridge Service
//  Placeholder for AMLL WebView bridge.
//

import Foundation

/// Stub implementation of LyricsBridgeServiceProtocol.
/// Records state for debugging; will be replaced by WKWebView bridge.
@Observable
@MainActor
final class StubLyricsBridgeService: LyricsBridgeServiceProtocol {

    // MARK: - Callbacks

    var onUserSeek: ((Double) -> Void)?

    // MARK: - Recorded State (for debugging)

    private(set) var lastTTML: String = ""
    private(set) var lastConfigJSON: String = "{}"
    private(set) var lastIsPlaying: Bool = false
    private(set) var lastTime: Double = 0

    // MARK: - Protocol Implementation

    func setLyricsTTML(_ text: String) {
        lastTTML = text
        #if DEBUG
            print("[StubLyricsBridge] setLyricsTTML: \(text.prefix(100))...")
        #endif
    }

    func setConfigJSON(_ json: String) {
        lastConfigJSON = json
        #if DEBUG
            print("[StubLyricsBridge] setConfigJSON: \(json.prefix(100))...")
        #endif
    }

    func setPlaying(_ isPlaying: Bool) {
        lastIsPlaying = isPlaying
        #if DEBUG
            print("[StubLyricsBridge] setPlaying: \(isPlaying)")
        #endif
    }

    func setCurrentTime(_ seconds: Double) {
        lastTime = seconds
        // Don't log every time update (too noisy)
    }

    // MARK: - Testing Helper

    /// Simulate a user seek from the lyrics UI.
    /// - Parameter seconds: Target time.
    func simulateUserSeek(to seconds: Double) {
        onUserSeek?(seconds)
    }
}
