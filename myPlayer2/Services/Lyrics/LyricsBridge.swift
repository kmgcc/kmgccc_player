//
//  LyricsBridge.swift
//  myPlayer2
//
//  TrueMusic - Lyrics Bridge (Swift <-> WKWebView)
//  Handles bidirectional communication with AMLL lyrics renderer.
//

import Foundation
import WebKit

/// Bridge for Swift <-> JavaScript communication with lyrics WebView.
/// Buffers calls until WebView is ready, throttles time updates.
@MainActor
final class LyricsBridge: NSObject, LyricsBridgeServiceProtocol {

    // MARK: - Published State

    private(set) var isReady: Bool = false
    private(set) var version: String = ""
    private(set) var capabilities: [String] = []

    // MARK: - Callbacks

    var onUserSeek: ((Double) -> Void)?

    // MARK: - WebView Reference

    private weak var webView: WKWebView?

    // MARK: - Buffering

    private var pendingCalls: [(String, String)] = []  // (method, jsonArgs)

    // MARK: - Last Known State (for reattach/reload)

    private var lastLyricsTTML: String?
    private var lastConfigJSON: String?
    private var lastIsPlaying: Bool?
    private var lastTime: Double?
    private var needsReplayOnReady: Bool = false
    private var lastReloadAt: Date = .distantPast
    private let minReloadInterval: TimeInterval = 2.0
    private var isReloadInFlight: Bool = false

    // MARK: - Throttling

    private var lastTimeUpdate: Date = .distantPast
    private let timeUpdateInterval: TimeInterval = 0.1  // 10 Hz max

    // MARK: - Web Content Lifecycle

    func markWebContentInvalidated(_ reason: String) {
        isReady = false
        needsReplayOnReady = true
        pendingCalls.removeAll()
        lastTimeUpdate = .distantPast
        print("[LyricsBridge] Web content invalidated: \(reason)")
    }

    // MARK: - Initialization

    override init() {
        super.init()
        print("[LyricsBridge] initialized")
    }

    // MARK: - Configuration

    /// Attach to a WKWebView and register message handlers.
    func attachToWebView(_ webView: WKWebView) {
        if self.webView === webView {
            return
        }

        // If SwiftUI recreates the WKWebView (e.g. panel toggles), ensure we
        // detach from the previous instance and reset readiness state.
        if self.webView != nil {
            detach()
        }

        self.webView = webView
        isReady = false
        version = ""
        capabilities = []
        pendingCalls.removeAll()
        lastTimeUpdate = .distantPast
        needsReplayOnReady = true
        isReloadInFlight = false

        // Register message handlers
        let contentController = webView.configuration.userContentController
        contentController.add(self, name: "onReady")
        contentController.add(self, name: "onUserSeek")
        contentController.add(self, name: "log")  // Added logging

        print("[LyricsBridge] attached to WebView")
    }

    var hasAttachedWebView: Bool {
        webView != nil
    }

    func reloadWebView(reason: String, force: Bool = false) {
        guard let webView else { return }
        if isReloadInFlight { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastReloadAt) < minReloadInterval {
            return
        }
        lastReloadAt = now
        isReloadInFlight = true
        markWebContentInvalidated("reload requested: \(reason)")
        webView.reload()
    }

    func notifyWebNavigationFinished() {
        isReloadInFlight = false
    }

    /// Detach from WebView (cleanup).
    func detach() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "onReady")
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: "onUserSeek")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "log")
        webView = nil
        isReady = false
        version = ""
        capabilities = []
        pendingCalls.removeAll()
        isReloadInFlight = false
        print("[LyricsBridge] detached")
    }

    // MARK: - LyricsBridgeServiceProtocol

    // MARK: - LyricsBridgeServiceProtocol

    func setLyricsTTML(_ ttmlText: String) {
        lastLyricsTTML = ttmlText
        // Enforce JSON serialization for safe string passing
        if let jsonArg = toJSONArg(ttmlText) {
            callJS("window.AMLL.setLyricsTTML(\(jsonArg))")
        } else {
            print("[LyricsBridge] Failed to encode TTML text")
        }
    }

    func setCurrentTime(_ seconds: Double) {
        guard seconds.isFinite else { return }
        lastTime = seconds
        // Throttle time updates to 10 Hz
        let now = Date()
        guard now.timeIntervalSince(lastTimeUpdate) >= timeUpdateInterval else {
            return
        }
        lastTimeUpdate = now

        // Don't buffer time updates
        guard isReady, let webView = webView else { return }

        // Use strict JSON for number
        let js = "window.AMLL.setCurrentTime(\(seconds))"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("[LyricsBridge] setCurrentTime error: \(error.localizedDescription)")
            }
        }
    }

    func setPlaying(_ isPlaying: Bool) {
        lastIsPlaying = isPlaying
        let boolStr = isPlaying ? "true" : "false"
        callJS("window.AMLL.setPlaying(\(boolStr))")
    }

    func setConfigJSON(_ json: String) {
        lastConfigJSON = json
        // 'json' is already a JSON string representation of an object, e.g. {"fontSize": 12}
        // We pass it directly to the JS function which expects an object.
        // HOWEVER, if the JS function expects an OBJECT, we should parse this JSON string
        // or ensure the JS side parses it.
        // Assuming JS expects an object: window.AMLL.setConfig({...})
        // But 'json' is a STRING.
        // If 'json' is literally '{"a":1}', interpolating it => window.AMLL.setConfig({"a":1}) which works.
        callJS("window.AMLL.setConfig(\(json))")
    }

    // MARK: - Private Methods

    /// Helper: Encode string to JSON argument (e.g. "foo" -> "\"foo\"")
    private func toJSONArg(_ string: String) -> String? {
        guard let data = try? JSONEncoder().encode([string]),
            let jsonArray = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        // JSONEncoder encodes ["string"] -> "[\"string\"]"
        // We strip the outer brackets to get "\"string\""
        let trimmed = jsonArray.dropFirst().dropLast()
        return String(trimmed)
    }

    /// Call JS method, buffering if not ready.
    private func callJS(_ script: String) {
        if isReady, let webView = webView {
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    print("[LyricsBridge] JS error: \(error)")
                    // Log prefix for debugging
                    let debugScript =
                        script.count > 180 ? String(script.prefix(180)) + "..." : script
                    print("[LyricsBridge] Failed script (prefix): \(debugScript)")
                }
            }
        } else {
            // Buffer call
            pendingCalls.append((script, ""))
        }
    }

    /// Flush pending calls after ready.
    private func flushPendingCalls() {
        guard isReady, let webView = webView else { return }

        print("[LyricsBridge] Flushing \(pendingCalls.count) pending calls")

        for (script, _) in pendingCalls {
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    print("[LyricsBridge] Flush error: \(error.localizedDescription)")
                    let debugScript =
                        script.count > 180 ? String(script.prefix(180)) + "..." : script
                    print("[LyricsBridge] Failed script (prefix): \(debugScript)")
                }
            }
        }

        pendingCalls.removeAll()
    }
}

// MARK: - WKScriptMessageHandler

extension LyricsBridge: WKScriptMessageHandler {

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            handleMessage(name: message.name, body: message.body)
        }
    }

    private func handleMessage(name: String, body: Any) {
        switch name {
        case "onReady":
            handleOnReady(body)

        case "onUserSeek":
            handleOnUserSeek(body)

        case "log":
            print("[AMLLWeb] \(body)")

        default:
            print("[LyricsBridge] Unknown message: \(name)")
        }
    }

    private func handleOnReady(_ body: Any) {
        guard let dict = body as? [String: Any] else { return }

        version = dict["version"] as? String ?? "unknown"
        capabilities = dict["capabilities"] as? [String] ?? []
        isReady = true
        isReloadInFlight = false

        print("[LyricsBridge] Ready - version: \(version), capabilities: \(capabilities)")

        if needsReplayOnReady {
            needsReplayOnReady = false
            replayLastState()
        }

        flushPendingCalls()
    }

    private func handleOnUserSeek(_ body: Any) {
        guard let dict = body as? [String: Any],
            let seconds = dict["seconds"] as? Double
        else {
            print("[LyricsBridge] Invalid onUserSeek payload: \(body)")
            return
        }

        // Validate
        guard seconds >= 0 else {
            print("[LyricsBridge] Invalid seek time: \(seconds)")
            return
        }

        print("[LyricsBridge] User seek to \(String(format: "%.2f", seconds))s")
        onUserSeek?(seconds)
    }

    // MARK: - Replay

    private func replayLastState() {
        if let lastConfigJSON {
            callJS("window.AMLL.setConfig(\(lastConfigJSON))")
        }

        if let lastLyricsTTML, let jsonArg = toJSONArg(lastLyricsTTML) {
            callJS("window.AMLL.setLyricsTTML(\(jsonArg))")
        }

        if let lastIsPlaying {
            let boolStr = lastIsPlaying ? "true" : "false"
            callJS("window.AMLL.setPlaying(\(boolStr))")
        }

        if let lastTime {
            lastTimeUpdate = .distantPast
            setCurrentTime(lastTime)
        }
    }
}
