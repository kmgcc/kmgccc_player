//
//  LyricsDebugFlags.swift
//  myPlayer2
//
//  Diagnostic flags for window lyrics performance investigation.
//  Toggle via `defaults write kmgccc.player <key> -bool YES` and relaunch.
//  All flags are read at initialization time; a relaunch is required to change them.
//

import Foundation

enum LyricsDebugFlags {
    /// Replace the SwiftUI NSHostingController lyrics inspector pane with a flat
    /// AppKit view controller that embeds the WKWebView directly.
    /// Tests whether the SwiftUI inspector host hierarchy is a compositing overhead.
    /// Enable: defaults write kmgccc.player lyrics.debug.windowUseFlatAppKitHost -bool YES
    static var windowUseFlatAppKitHost: Bool {
        UserDefaults.standard.bool(forKey: "lyrics.debug.windowUseFlatAppKitHost")
    }
}
