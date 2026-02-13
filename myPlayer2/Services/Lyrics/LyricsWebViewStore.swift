//
//  LyricsWebViewStore.swift
//  myPlayer2
//
//  kmgccc_player - Singleton WebView Owner for AMLL Lyrics
//  Ensures WKWebView instance is NEVER recreated by SwiftUI.
//

import Combine
import CryptoKit
import Foundation
import SwiftUI
import WebKit

/// Singleton store that owns the single WKWebView instance for AMLL lyrics.
/// This prevents SwiftUI view lifecycle from destroying/recreating the WebView.
@MainActor
@Observable
final class LyricsWebViewStore: NSObject {

    // MARK: - Singleton

    static let shared = LyricsWebViewStore()

    // MARK: - WebView Identity

    /// The single WKWebView instance (created once, reused forever).
    let webView: WKWebView

    /// Unique identifier for the WebView instance (for logging).
    let webViewObjectID: Int

    /// Current active attachment ID (for instance-aware detach).
    private(set) var activeAttachmentID: UUID?

    /// Whether an attach has occurred (prevents duplicate attach in updateNSView).
    private(set) var isAttached: Bool = false

    // MARK: - State

    private(set) var isReady: Bool = false

    /// Last known state for replay after recovery (NEVER cleared on terminate).
    private var lastTTML: String?
    private var lastTime: Double?
    private var lastIsPlaying: Bool?
    private var lastConfigJSON: String?

    /// Pending JS calls queue (flushed when ready).
    private var pendingCalls: [String] = []

    /// Recovery state.
    private var isRecoveryInProgress: Bool = false
    private var lastRecoveryAttempt: Date = .distantPast
    private let recoveryDebounceInterval: TimeInterval = 1.0

    /// Track change debounce (prevents transient nil clearing).
    private var pendingApplyTrack: DispatchWorkItem?
    private let applyTrackDebounceMs: Int = 50

    // MARK: - Callbacks

    var onUserSeek: ((Double) -> Void)?

    // MARK: - Initialization

    private override init() {
        // Create WKWebView configuration
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        // Create the single WebView instance
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        self.webView = wv
        self.webViewObjectID = ObjectIdentifier(wv).hashValue

        super.init()

        // Register message handlers
        let contentController = webView.configuration.userContentController
        contentController.add(self, name: "onReady")
        contentController.add(self, name: "onUserSeek")
        contentController.add(self, name: "log")

        print("[LyricsStore] ✅ Created WebView instance: objectID=\(webViewObjectID)")

        // Load initial content
        loadAMLLContent()
    }

    // MARK: - Content Loading

    func loadAMLLContent() {
        guard
            let indexURL = Bundle.main.url(
                forResource: "index", withExtension: "html", subdirectory: "AMLL"
            )
        else {
            print(
                "[LyricsStore] ❌ AMLL/index.html not found in bundle, objectID=\(webViewObjectID)")
            return
        }

        let amllDir = indexURL.deletingLastPathComponent()
        print(
            "[LyricsStore] Loading AMLL from: \(indexURL.lastPathComponent), objectID=\(webViewObjectID)"
        )
        webView.loadFileURL(indexURL, allowingReadAccessTo: amllDir)
    }

    // MARK: - Attach/Detach (Instance-Aware + Dedup)

    /// Attach a new view to the store. Returns the attachment ID.
    /// This is idempotent - will return existing ID if already attached.
    func attach() -> UUID {
        if isAttached, let existingID = activeAttachmentID {
            print(
                "[LyricsStore] Attach (already attached): attachmentID=\(existingID.uuidString.prefix(8)), objectID=\(webViewObjectID)"
            )
            return existingID
        }

        let attachmentID = UUID()
        activeAttachmentID = attachmentID
        isAttached = true
        print(
            "[LyricsStore] Attach (new): attachmentID=\(attachmentID.uuidString.prefix(8)), objectID=\(webViewObjectID)"
        )
        return attachmentID
    }

    /// Detach from the store. Only succeeds if the requesting ID matches the active one.
    func detach(requestingID: UUID) {
        guard requestingID == activeAttachmentID else {
            print(
                "[LyricsStore] ⚠️ Ignoring detach: requestingID=\(requestingID.uuidString.prefix(8)), activeID=\(activeAttachmentID?.uuidString.prefix(8) ?? "nil"), objectID=\(webViewObjectID)"
            )
            return
        }

        print(
            "[LyricsStore] Detach: attachmentID=\(requestingID.uuidString.prefix(8)), objectID=\(webViewObjectID)"
        )
        activeAttachmentID = nil
        isAttached = false
        // Note: We do NOT clear isReady or state here. The WebView persists.
    }

    // MARK: - JS Calls (Queued + Snapshot Preserved)

    func setLyricsTTML(_ ttml: String) {
        lastTTML = ttml
        print(
            "[LyricsStore] setLyricsTTML: len=\(ttml.count), objectID=\(webViewObjectID), isReady=\(isReady)"
        )
        logTTMLDiagnostics(ttml, stage: "setLyricsTTML")
        guard let jsonArg = encodeJSONString(ttml) else {
            print("[LyricsStore] Failed to encode TTML")
            return
        }
        callJS("window.AMLL.setLyricsTTML(\(jsonArg))")
    }

    func setCurrentTime(_ seconds: Double) {
        guard seconds.isFinite else { return }
        lastTime = seconds
        // Time updates are not queued (too frequent), only sent if ready
        guard isReady else { return }
        let js = "window.AMLL.setCurrentTime(\(seconds))"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("[LyricsStore] setCurrentTime error: \(error.localizedDescription)")
            }
        }
    }

    func setPlaying(_ isPlaying: Bool) {
        lastIsPlaying = isPlaying
        print(
            "[LyricsStore] setPlaying: \(isPlaying), objectID=\(webViewObjectID), isReady=\(isReady)"
        )
        let boolStr = isPlaying ? "true" : "false"
        callJS("window.AMLL.setPlaying(\(boolStr))")
    }

    func setConfigJSON(_ json: String) {
        lastConfigJSON = json
        callJS("window.AMLL.setConfig(\(json))")
    }

    /// Unified JS call entry point with queuing.
    private func callJS(_ script: String) {
        if isReady {
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    let debugScript =
                        script.count > 100 ? String(script.prefix(100)) + "..." : script
                    print(
                        "[LyricsStore] JS error: \(error.localizedDescription), script: \(debugScript)"
                    )
                }
            }
        } else {
            pendingCalls.append(script)
            print(
                "[LyricsStore] Queued (pending=\(pendingCalls.count)), objectID=\(webViewObjectID)")
        }
    }

    // MARK: - Ready Handling

    private func handleOnReady(_ body: Any) {
        guard let dict = body as? [String: Any] else { return }

        let version = dict["version"] as? String ?? "unknown"
        let capabilities = dict["capabilities"] as? [String] ?? []

        isReady = true
        isRecoveryInProgress = false

        print(
            "[LyricsStore] ✅ Ready: version=\(version), caps=\(capabilities.count), objectID=\(webViewObjectID)"
        )

        // Flush pending calls
        flushPendingCalls()

        // Replay last state snapshot (strict order)
        replayStateSnapshot()
    }

    private func flushPendingCalls() {
        let queuedCount = pendingCalls.count
        guard queuedCount > 0 else {
            print("[LyricsStore] Flush: 0 queued, objectID=\(webViewObjectID)")
            return
        }

        print("[LyricsStore] Flush: \(queuedCount) queued, objectID=\(webViewObjectID)")
        for script in pendingCalls {
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    print("[LyricsStore] Flush error: \(error.localizedDescription)")
                }
            }
        }
        pendingCalls.removeAll()
        print("[LyricsStore] Flushed: \(queuedCount), objectID=\(webViewObjectID)")
    }

    /// Replay the last known state after recovery.
    /// Order: Config -> TTML -> Playing -> Time
    private func replayStateSnapshot() {
        print(
            "[LyricsStore] Replay: ttml=\(lastTTML != nil), time=\(lastTime ?? -1), playing=\(lastIsPlaying ?? false), objectID=\(webViewObjectID)"
        )

        // Step 1: Config
        if let config = lastConfigJSON {
            let js = "window.AMLL.setConfig(\(config))"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // Step 2: TTML
        if let ttml = lastTTML, let jsonArg = encodeJSONString(ttml) {
            logTTMLDiagnostics(ttml, stage: "replayStateSnapshot")
            let js = "window.AMLL.setLyricsTTML(\(jsonArg))"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // Step 3: Playing
        if let playing = lastIsPlaying {
            let js = "window.AMLL.setPlaying(\(playing ? "true" : "false"))"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // Step 4: Time
        if let time = lastTime {
            let js = "window.AMLL.setCurrentTime(\(time))"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        print("[LyricsStore] Replay complete, objectID=\(webViewObjectID)")
    }

    // MARK: - Recovery (Task B: Closed-loop)

    /// Called when web content process terminates.
    func handleWebContentTerminated() {
        let now = Date()
        guard now.timeIntervalSince(lastRecoveryAttempt) > recoveryDebounceInterval else {
            print("[LyricsStore] Recovery debounced, objectID=\(webViewObjectID)")
            return
        }

        lastRecoveryAttempt = now
        isReady = false
        isRecoveryInProgress = true

        // Clear pending queue but PRESERVE snapshot (lastTTML/lastTime/lastPlaying/lastConfig)
        pendingCalls.removeAll()

        print(
            "[LyricsStore] ⚠️ Terminated: objectID=\(webViewObjectID), snapshot preserved (ttml=\(lastTTML != nil), time=\(lastTime ?? -1), playing=\(lastIsPlaying ?? false))"
        )

        // Reload AMLL content - state will be replayed when onReady fires
        print("[LyricsStore] Reload: objectID=\(webViewObjectID)")
        loadAMLLContent()
    }

    /// Force reload (for manual recovery).
    func forceReload() {
        isReady = false
        pendingCalls.removeAll()
        print("[LyricsStore] Force reload, objectID=\(webViewObjectID)")
        loadAMLLContent()
    }

    // MARK: - Track Change (Task D: Race-safe)

    /// Apply a new track with debounce to prevent transient nil clearing.
    func applyTrack(ttml: String?, currentTime: Double, isPlaying: Bool) {
        // Cancel any pending apply
        pendingApplyTrack?.cancel()

        // If ttml is nil/empty, debounce to avoid transient clearing
        if ttml == nil || ttml?.isEmpty == true {
            let workItem = DispatchWorkItem { [weak self] in
                self?.executeApplyTrack(ttml: ttml, currentTime: currentTime, isPlaying: isPlaying)
            }
            pendingApplyTrack = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(applyTrackDebounceMs), execute: workItem)
            print("[LyricsStore] applyTrack: debounced nil/empty, objectID=\(webViewObjectID)")
        } else {
            // Immediate apply for non-nil
            executeApplyTrack(ttml: ttml, currentTime: currentTime, isPlaying: isPlaying)
        }
    }

    private func executeApplyTrack(ttml: String?, currentTime: Double, isPlaying: Bool) {
        print(
            "[LyricsStore] applyTrack: ttmlLen=\(ttml?.count ?? 0), time=\(currentTime), playing=\(isPlaying), objectID=\(webViewObjectID)"
        )

        // Step 1: Pause
        setPlaying(false)

        // Step 2: Set lyrics
        setLyricsTTML(ttml ?? "")

        // Step 3: Set time
        setCurrentTime(currentTime)

        // Step 4: Resume playing state
        setPlaying(isPlaying)
    }

    // MARK: - Theme Application

    /// Apply a unified theme palette to the WebView.
    /// Sets config theme and injects CSS variables for deep styling.
    func applyTheme(_ palette: ThemePalette) {
        let themeName = (palette.scheme == .dark) ? "dark" : "light"
        print("[LyricsStore] applyTheme: theme=\(themeName), objectID=\(webViewObjectID)")

        // 1. Update config JSON (bridge-level metadata)
        let config: [String: Any] = [
            "theme": themeName,
            "textColor": palette.text,
            "shadowColor": palette.shadow,
        ]

        if let data = try? JSONSerialization.data(withJSONObject: config),
            let json = String(data: data, encoding: .utf8)
        {
            setConfigJSON(json)
        }

        // 2. Inject CSS Variables (renderer-level styles)
        let css = """
            (function() {
                var root = document.documentElement;
                root.style.setProperty('--amll-bg', '\(palette.background)');
                root.style.setProperty('--amll-text', '\(palette.text)');
                root.style.setProperty('--amll-active', '\(palette.activeLine)');
                root.style.setProperty('--amll-inactive', '\(palette.inactiveLine)');
                root.style.setProperty('--amll-accent', '\(palette.accent)');
                root.style.setProperty('--amll-shadow', '\(palette.shadow)');
            })();
            """
        callJS(css)

        // 3. Replay state to ensure immediate visual refresh if already ready
        if isReady {
            replayStateSnapshot()
        }
    }

    // MARK: - Helpers

    private func logTTMLDiagnostics(_ ttml: String, stage: String) {
        let sha = sha256Hex(ttml)
        print(
            "[LyricsStore][TTML][\(stage)] sha256=\(sha), utf8=\(ttml.utf8.count), chars=\(ttml.count)"
        )
        print("[LyricsStore][TTML][\(stage)] head200=\(escapedLogSnippet(String(ttml.prefix(200))))")
        print("[LyricsStore][TTML][\(stage)] tail200=\(escapedLogSnippet(String(ttml.suffix(200))))")

        let xbgPattern = "ttm:role=\"x-bg\""
        guard let roleRange = ttml.range(of: xbgPattern) ?? ttml.range(of: "role=\"x-bg\"") else {
            print("[LyricsStore][TTML][\(stage)] x-bg not found")
            return
        }
        let start = ttml.index(roleRange.lowerBound, offsetBy: -200, limitedBy: ttml.startIndex)
            ?? ttml.startIndex
        let end = ttml.index(roleRange.upperBound, offsetBy: 200, limitedBy: ttml.endIndex)
            ?? ttml.endIndex
        let slice = String(ttml[start..<end])
        print("[LyricsStore][TTML][\(stage)] xbgWindow=\(escapedLogSnippet(slice))")
    }

    private func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func escapedLogSnippet(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func encodeJSONString(_ string: String) -> String? {
        // Enforce valid JSON string logic
        guard let data = try? JSONEncoder().encode([string]),
            let jsonArray = String(data: data, encoding: .utf8)
        else { return nil }

        // JSONEncoder(["foo"]) -> ["foo"]
        // We want "foo" (including quotes) for JS function arg
        // dropFirst is '[', dropLast is ']'
        let trimmed = jsonArray.dropFirst().dropLast()
        return String(trimmed)
    }
}

// MARK: - WKScriptMessageHandler

extension LyricsWebViewStore: WKScriptMessageHandler {

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            switch message.name {
            case "onReady":
                handleOnReady(message.body)
            case "onUserSeek":
                handleOnUserSeek(message.body)
            case "log":
                print("[AMLLWeb] \(message.body)")
            default:
                print("[LyricsStore] Unknown message: \(message.name)")
            }
        }
    }

    private func handleOnUserSeek(_ body: Any) {
        guard let dict = body as? [String: Any],
            let seconds = dict["seconds"] as? Double,
            seconds >= 0
        else { return }

        print(
            "[LyricsStore] User seek: \(String(format: "%.2f", seconds))s, objectID=\(webViewObjectID)"
        )
        onUserSeek?(seconds)
    }
}
