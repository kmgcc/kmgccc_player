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

    // MARK: - Fullscreen layer-volatility investigation

    // These are env-gated (launch-time) so they never affect release builds and
    // require no settings UI. They exist to diagnose the
    // `WebProcess::markAllLayersVolatile: Failed to mark layers as volatile`
    // flood that only occurs on the fullscreen AMLL surface.

    /// DEBUG A/B: render the fullscreen AMLL WKWebView with **no** SwiftUI
    /// compositing wrapper — no `.mask`, `.opacity`, `.blendMode`,
    /// `.compositingGroup`, or `.scaleEffect` — mirroring the window flat host
    /// (`LyricsFlatAppKitHostViewController`) which adds the WebView directly to
    /// the layer tree and does not flood.
    ///
    /// Enable to confirm the wrapper is the trigger:
    /// `KMGCCC_AMLL_FULLSCREEN_NO_WRAPPER=1`
    /// If the flood stops with this on, the SwiftUI compositing wrapper is the
    /// root cause and the definitive fix is the flat-AppKit-host port.
    /// Visual fade/scale are intentionally dropped while this is on — it is a
    /// diagnostic mode, not a shipping configuration.
    static var fullscreenDisableSwiftUIWrapper: Bool {
        ProcessInfo.processInfo.environment["KMGCCC_AMLL_FULLSCREEN_NO_WRAPPER"] == "1"
    }

    /// DEBUG: periodically log fullscreen AMLL layer-stability signals — the
    /// WebView's window occlusion state, `isHidden`, `alphaValue`, frame,
    /// superview, plus the active SwiftUI wrapper config — so they can be
    /// correlated against `markAllLayersVolatile` floods in Console.app.
    /// `KMGCCC_AMLL_FULLSCREEN_LAYER_DIAGNOSTICS=1`
    static var fullscreenLayerDiagnosticsEnabled: Bool {
        ProcessInfo.processInfo.environment["KMGCCC_AMLL_FULLSCREEN_LAYER_DIAGNOSTICS"] == "1"
    }
}
