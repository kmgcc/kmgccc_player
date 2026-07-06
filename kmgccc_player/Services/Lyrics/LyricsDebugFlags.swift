//
//  LyricsDebugFlags.swift
//  myPlayer2
//
//  Compatibility flags for window lyrics performance investigation.
//  Toggle via `defaults write kmgccc.player <key> -bool NO` and relaunch.
//  All flags are read at initialization time; a relaunch is required to change them.
//

import Foundation

enum LyricsDebugFlags {
    /// Replace the SwiftUI NSHostingController lyrics inspector pane with a flat
    /// AppKit view controller that embeds the WKWebView directly.
    /// The flat host is now the default window lyrics path. Disable only when
    /// comparing against the old SwiftUI inspector host:
    /// defaults write kmgccc.player lyrics.debug.windowUseFlatAppKitHost -bool NO
    static var windowUseFlatAppKitHost: Bool {
        let key = "lyrics.debug.windowUseFlatAppKitHost"
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }
}
