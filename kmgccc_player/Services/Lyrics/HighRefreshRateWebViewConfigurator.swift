//
//  HighRefreshRateWebViewConfigurator.swift
//  myPlayer2
//
//  Best-effort WebKit configuration for display-native rendering updates.
//

import Foundation
import WebKit

@MainActor
enum HighRefreshRateWebViewConfigurator {
    /// WebKit does not expose a supported refresh-rate preference. The app uses
    /// the system default rather than relying on private runtime SPI.
    @discardableResult
    static func enableHighRefreshRate(in _: WKWebViewConfiguration) -> Bool {
        Log.info(
            "[HighRefreshRateWebView] using WebKit default refresh rate",
            category: .webview
        )
        return false
    }
}
