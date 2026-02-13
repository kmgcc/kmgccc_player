//
//  LyricsBridgeServiceProtocol.swift
//  myPlayer2
//
//  kmgccc_player - Lyrics Bridge Service Protocol
//  Defines interface for WKWebView + AMLL communication.
//

import Foundation

/// Protocol for AMLL lyrics bridge.
/// Handles Swift <-> JavaScript communication for the lyrics WebView.
@MainActor
protocol LyricsBridgeServiceProtocol: AnyObject {

    // MARK: - Callbacks

    /// Callback when user seeks via lyrics UI (tapping on a lyric line).
    /// The TimeInterval is the target time in seconds.
    var onUserSeek: ((Double) -> Void)? { get set }

    // MARK: - Swift -> JS

    /// Set TTML/LRC lyrics content.
    /// - Parameter text: Lyrics text (TTML or LRC format).
    func setLyricsTTML(_ text: String)

    /// Set AMLL configuration as JSON string.
    /// - Parameter json: Configuration JSON.
    func setConfigJSON(_ json: String)

    /// Set playback state.
    /// - Parameter isPlaying: Whether audio is playing.
    func setPlaying(_ isPlaying: Bool)

    /// Sync current playback time.
    /// - Parameter seconds: Current playback position.
    func setCurrentTime(_ seconds: Double)
}
