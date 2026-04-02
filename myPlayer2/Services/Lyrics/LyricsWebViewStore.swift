//
//  LyricsWebViewStore.swift
//  myPlayer2
//
//  kmgccc_player - WebView Owner for AMLL Lyrics
//  Owns one WKWebView instance for a specific lyrics surface.
//

import Combine
import CryptoKit
import Foundation
import SwiftUI
import WebKit

/// Store that owns a single WKWebView instance for one AMLL surface.
/// This prevents SwiftUI view lifecycle from destroying/recreating the WebView.
@MainActor
@Observable
final class LyricsWebViewStore: NSObject {

    // MARK: - Singleton

    static let shared = LyricsWebViewStore()
    private nonisolated static let ttmlDiagnosticsEnabled =
        ProcessInfo.processInfo.environment["AMLL_TTML_DIAGNOSTICS"] == "1"
    private nonisolated static let visibleLayerProbeEnabled =
        ProcessInfo.processInfo.environment["KMGCCC_AMLL_VISIBLE_LAYER_PROBE"] == "1"

    // MARK: - WebView Identity

    let role: String

    /// The single WKWebView instance, created lazily on first visible attachment.
    private var retainedWebView: WKWebView?

    /// Unique identifier for the WebView instance (for logging).
    private let fallbackObjectID: Int

    var webView: WKWebView {
        ensureWebView()
    }

    var preparedWebView: WKWebView? {
        retainedWebView
    }

    var hasPreparedWebView: Bool {
        retainedWebView != nil
    }

    var webViewObjectID: Int {
        retainedWebView.map { ObjectIdentifier($0).hashValue } ?? fallbackObjectID
    }

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
    private var lastThemeConfigPatchJSON: String?
    private var lastThemeCSSScript: String?
    private var baseThemePalette: ThemePalette?
    private var overrideThemePalette: ThemePalette?
    private var lastDeliveredTime: Double?
    private var queuedTimeSync: Double?
    private var isTimeSyncInFlight: Bool = false

    /// Pending JS calls queue (flushed when ready).
    private var pendingCalls: [String] = []

    /// Recovery state.
    private var isRecoveryInProgress: Bool = false
    private var lastRecoveryAttempt: Date = .distantPast
    private let recoveryDebounceInterval: TimeInterval = 1.0
    private var contentLoadRevision: Int = 0

    /// Track change debounce (prevents transient nil clearing).
    private var pendingApplyTrack: DispatchWorkItem?
    private var pendingVisibleLayerProbe: DispatchWorkItem?
    private let applyTrackDebounceMs: Int = 50
    private var didRegisterMessageHandlers = false
    private var isShutDown = false

    // MARK: - Callbacks

    var onUserSeek: ((Double) -> Void)?

    // MARK: - Initialization

    init(role: String = "main") {
        self.role = role
        self.fallbackObjectID = role.hashValue

        super.init()
        Log.debug("Prepared store (WebView deferred), role=\(role)", category: .webview)
    }

    // MARK: - Content Loading

    func loadAMLLContent(cacheBust: Bool = false) {
        guard !isShutDown else { return }
        let webView = ensureWebView()
        guard
            let indexURL = Bundle.main.url(
                forResource: "index", withExtension: "html", subdirectory: "AMLL"
            )
        else {
            Log.error("AMLL/index.html not found in bundle, objectID=\(webViewObjectID)", category: .webview)
            return
        }

        if cacheBust {
            contentLoadRevision &+= 1
        }

        let amllDir = indexURL.deletingLastPathComponent()
        let loadURL = resolvedAMLLLoadURL(from: indexURL)
        Log.debug("Loading AMLL from: \(loadURL.absoluteString) role=\(role), objectID=\(webViewObjectID)", category: .webview)
        webView.loadFileURL(loadURL, allowingReadAccessTo: amllDir)
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true

        // Cancel all pending operations
        pendingApplyTrack?.cancel()
        pendingApplyTrack = nil
        pendingVisibleLayerProbe?.cancel()
        pendingVisibleLayerProbe = nil
        pendingCalls.removeAll()
        onUserSeek = nil

        // Clear all state
        activeAttachmentID = nil
        isAttached = false
        isReady = false
        isRecoveryInProgress = false
        lastTTML = nil
        lastTime = nil
        lastIsPlaying = nil
        lastConfigJSON = nil
        lastThemeConfigPatchJSON = nil
        lastThemeCSSScript = nil
        baseThemePalette = nil
        overrideThemePalette = nil
        lastDeliveredTime = nil
        queuedTimeSync = nil
        isTimeSyncInFlight = false
        contentLoadRevision = 0
        didRegisterMessageHandlers = false

        // Clean up WebView
        if let webView = retainedWebView {
            // Stop any ongoing loading
            webView.stopLoading()

            // Clear the web view content to free memory
            webView.evaluateJavaScript("window.location.href = 'about:blank'") { _, _ in
                // Ignore errors
            }

            // Remove from view hierarchy
            webView.removeFromSuperview()

            // Clear delegates and handlers
            webView.navigationDelegate = nil
            webView.uiDelegate = nil

            // Remove all script message handlers
            let contentController = webView.configuration.userContentController
            contentController.removeScriptMessageHandler(forName: "onReady")
            contentController.removeScriptMessageHandler(forName: "onUserSeek")
            contentController.removeScriptMessageHandler(forName: "log")

            // Remove all user scripts
            contentController.removeAllUserScripts()

            // Clear caches
            WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeMemoryCache],
                                                    modifiedSince: Date(timeIntervalSince1970: 0)) { }
        }

        // Release the WebView reference
        retainedWebView = nil

        Log.info("Shutdown complete, objectID=\(webViewObjectID)", category: .webview)
    }

    // MARK: - Attach/Detach (Instance-Aware + Dedup)

    /// Attach a new view to the store. Returns the attachment ID.
    /// This is idempotent - will return existing ID if already attached.
    func attach() -> UUID {
        guard !isShutDown else {
            return UUID()
        }
        _ = ensureWebView()
        if isAttached, let existingID = activeAttachmentID {
            Log.debug("Attach (already attached): attachmentID=\(existingID.uuidString.prefix(8)), objectID=\(webViewObjectID)", category: .webview)
            return existingID
        }

        let attachmentID = UUID()
        activeAttachmentID = attachmentID
        isAttached = true
        Log.debug("Attach (new): attachmentID=\(attachmentID.uuidString.prefix(8)), objectID=\(webViewObjectID)", category: .webview)
        return attachmentID
    }

    /// Detach from the store. Only succeeds if the requesting ID matches the active one.
    func detach(requestingID: UUID) {
        guard requestingID == activeAttachmentID else {
            Log.warning("Ignoring detach: requestingID=\(requestingID.uuidString.prefix(8)), activeID=\(activeAttachmentID?.uuidString.prefix(8) ?? "nil"), objectID=\(webViewObjectID)", category: .webview)
            return
        }

        Log.debug("Detach: attachmentID=\(requestingID.uuidString.prefix(8)), objectID=\(webViewObjectID)", category: .webview)
        activeAttachmentID = nil
        isAttached = false
        // Note: We do NOT clear isReady or state here. The WebView persists.
    }

    // MARK: - JS Calls (Queued + Snapshot Preserved)

    func setLyricsTTML(_ ttml: String) {
        guard !isShutDown else { return }

        // Deduplication: skip if same TTML
        if ttml == lastTTML && ttml.count > 0 {
            return
        }

        lastTTML = ttml
        Log.debug("setLyricsTTML: len=\(ttml.count), objectID=\(webViewObjectID), isReady=\(isReady)", category: .webview)
        logTTMLDiagnostics(ttml, stage: "setLyricsTTML")
        guard let jsonArg = encodeJSONString(ttml) else {
            Log.error("Failed to encode TTML", category: .webview)
            return
        }
        callJS("window.AMLL.setLyricsTTML(\(jsonArg))")
    }

    func setCurrentTime(_ seconds: Double) {
        guard !isShutDown else { return }
        guard seconds.isFinite else { return }

        // Deduplication: skip if time hasn't changed meaningfully
        if let last = lastTime, abs(seconds - last) < 0.01 {
            return
        }

        lastTime = seconds
        // Time updates are not queued (too frequent), only sent if ready
        guard isReady else { return }
        scheduleTimeSync(seconds)
    }

    func setPlaying(_ isPlaying: Bool) {
        guard !isShutDown else { return }

        // Deduplication: skip if same state
        if isPlaying == lastIsPlaying {
            return
        }

        lastIsPlaying = isPlaying
        Log.debug("setPlaying: \(isPlaying)", category: .webview)
        let boolStr = isPlaying ? "true" : "false"
        callJS("window.AMLL.setPlaying(\(boolStr))")
    }

    func setConfigJSON(_ json: String) {
        guard !isShutDown else { return }

        // Deduplication: skip if same config
        if json == lastConfigJSON {
            return
        }

        lastConfigJSON = json
        callJS("window.AMLL.setConfig(\(json))")
    }

    /// Force set config JSON bypassing deduplication.
    /// Use when appearance/colorScheme changes require guaranteed delivery.
    func forceSetConfigJSON(_ json: String, reason: String) {
        guard !isShutDown else { return }

        Log.debug("forceSetConfigJSON: reason=\(reason), webViewObjectID=\(webViewObjectID), jsonChanged=\(json != lastConfigJSON)", category: .webview)

        lastConfigJSON = json
        callJS("window.AMLL.setConfig(\(json))")
    }

    func scheduleDebugVisibleLayerProbe(label: String, delay: TimeInterval = 0.18) {
        guard !isShutDown else { return }
        guard role == "fullscreen" || role == "main" || role == "fullscreenCoverBlurHighlight" else {
            return
        }
        guard Self.visibleLayerProbeEnabled else { return }

        pendingVisibleLayerProbe?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.runDebugVisibleLayerProbe(label: label)
        }
        pendingVisibleLayerProbe = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Unified JS call entry point with queuing.
    private func callJS(_ script: String) {
        guard !isShutDown else { return }
        if isReady {
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    let debugScript =
                        script.count > 100 ? String(script.prefix(100)) + "..." : script
                    Log.debug("JS error: \(error.localizedDescription), script: \(debugScript)", category: .webview)
                }
            }
        } else {
            pendingCalls.append(script)
            Log.debug("Queued (pending=\(pendingCalls.count)), objectID=\(webViewObjectID)", category: .webview)
        }
    }

    private func runDebugVisibleLayerProbe(label: String) {
        guard !isShutDown, isReady else { return }
        guard let labelJSON = encodeJSONString(label) else { return }

        let js = """
            (function() {
                if (!window.AMLL || typeof window.AMLL.debugDumpVisibleLayers !== "function") {
                    return JSON.stringify({
                        role: "\(role)",
                        error: "debugDumpVisibleLayers unavailable"
                    });
                }
                return JSON.stringify(window.AMLL.debugDumpVisibleLayers(\(labelJSON)));
            })();
            """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            if let error {
                Log.debug("[Probe] role=\(self.role) label=\(label) error=\(error.localizedDescription)", category: .webview)
                return
            }
            let payload = result as? String ?? String(describing: result ?? "nil")
            Log.debug("[Probe] role=\(self.role) label=\(label) payload=\(payload)", category: .webview)
        }
    }

    // MARK: - Ready Handling

    private func handleOnReady(_ body: Any) {
        guard let dict = body as? [String: Any] else { return }

        let version = dict["version"] as? String ?? "unknown"
        let capabilities = dict["capabilities"] as? [String] ?? []

        isReady = true
        isRecoveryInProgress = false

        Log.info("Ready: version=\(version), caps=\(capabilities.count), objectID=\(webViewObjectID)", category: .webview)

        // Flush pending calls
        flushPendingCalls()

        // Replay last state snapshot (strict order)
        replayStateSnapshot()
        scheduleDebugVisibleLayerProbe(label: "\(role)-ready", delay: 0.75)

        // Notify LyricsSurfaceManager that this store is ready
        if let surfaceRole = LyricsSurfaceRole(rawValue: role) {
            LyricsSurfaceManager.shared.notifyStoreReady(surfaceRole, store: self)
        }
    }

    private func flushPendingCalls() {
        let queuedCount = pendingCalls.count
        guard queuedCount > 0 else {
            Log.debug("Flush: 0 queued, objectID=\(webViewObjectID)", category: .webview)
            return
        }

        Log.debug("Flush: \(queuedCount) queued, objectID=\(webViewObjectID)", category: .webview)
        for script in pendingCalls {
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    Log.debug("Flush error: \(error.localizedDescription)", category: .webview)
                }
            }
        }
        pendingCalls.removeAll()
        Log.debug("Flushed: \(queuedCount), objectID=\(webViewObjectID)", category: .webview)
    }

    /// Replay the last known state after recovery.
    /// Order: Config -> TTML -> Playing -> Time
    private func replayStateSnapshot() {
        Log.debug("Replay: ttml=\(lastTTML != nil), time=\(lastTime ?? -1), playing=\(lastIsPlaying ?? false), objectID=\(webViewObjectID)", category: .webview)

        // Step 1: Config
        if let config = lastConfigJSON {
            let js = "window.AMLL.setConfig(\(config))"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        if let themeConfig = lastThemeConfigPatchJSON {
            let js = "window.AMLL.setConfig(\(themeConfig))"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        if let themeCSS = lastThemeCSSScript {
            webView.evaluateJavaScript(themeCSS, completionHandler: nil)
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
            queuedTimeSync = nil
            isTimeSyncInFlight = false
            lastDeliveredTime = nil
            dispatchTimeSync(time)
        }

        Log.debug("Replay complete, objectID=\(webViewObjectID)", category: .webview)
    }

    // MARK: - Recovery (Task B: Closed-loop)

    /// Called when web content process terminates.
    func handleWebContentTerminated() {
        guard !isShutDown else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRecoveryAttempt) > recoveryDebounceInterval else {
            Log.debug("Recovery debounced, objectID=\(webViewObjectID)", category: .webview)
            return
        }

        lastRecoveryAttempt = now
        isReady = false
        isRecoveryInProgress = true

        // Clear pending queue but PRESERVE snapshot (lastTTML/lastTime/lastPlaying/lastConfig)
        pendingCalls.removeAll()
        queuedTimeSync = nil
        isTimeSyncInFlight = false
        lastDeliveredTime = nil

        Log.warning("Terminated: objectID=\(webViewObjectID), snapshot preserved (ttml=\(lastTTML != nil), time=\(lastTime ?? -1), playing=\(lastIsPlaying ?? false))", category: .webview)

        // Reload AMLL content - state will be replayed when onReady fires
        Log.debug("Reload: objectID=\(webViewObjectID)", category: .webview)
        loadAMLLContent(cacheBust: role == LyricsSurfaceRole.fullscreen.rawValue)
    }

    /// Force reload (for manual recovery).
    func forceReload(recreateWebView: Bool = false) {
        guard !isShutDown else { return }
        isReady = false
        pendingCalls.removeAll()
        queuedTimeSync = nil
        isTimeSyncInFlight = false
        lastDeliveredTime = nil
        Log.debug("Force reload, objectID=\(webViewObjectID), recreateWebView=\(recreateWebView)", category: .webview)
        if recreateWebView {
            rebuildWebViewForFreshContent()
        } else {
            loadAMLLContent(cacheBust: true)
        }
    }

    // MARK: - Track Change (Task D: Race-safe)

    /// Apply a new track with debounce to prevent transient nil clearing.
    /// - Note: `nil` means transition state and is debounced.
    ///         Empty string means concrete "no lyrics" and should clear immediately.
    func applyTrack(ttml: String?, currentTime: Double, isPlaying: Bool) {
        // Cancel any pending apply
        pendingApplyTrack?.cancel()

        // Debounce only transitional nil (e.g. oldTrack -> nil -> newTrack)
        if ttml == nil {
            let workItem = DispatchWorkItem { [weak self] in
                self?.executeApplyTrack(ttml: ttml, currentTime: currentTime, isPlaying: isPlaying)
            }
            pendingApplyTrack = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(applyTrackDebounceMs), execute: workItem)
            Log.debug("applyTrack: debounced nil, objectID=\(webViewObjectID)", category: .webview)
        } else {
            // Immediate apply for concrete payload (including empty string clear)
            executeApplyTrack(ttml: ttml, currentTime: currentTime, isPlaying: isPlaying)
        }
    }

    private func executeApplyTrack(ttml: String?, currentTime: Double, isPlaying: Bool) {
        Log.debug("applyTrack: ttmlLen=\(ttml?.count ?? 0), time=\(currentTime), playing=\(isPlaying), objectID=\(webViewObjectID)", category: .webview)

        // Step 1: Clear previous lyrics state to free memory
        clearLyricsState()

        // Step 2: Pause
        setPlaying(false)

        // Step 3: Set lyrics
        setLyricsTTML(ttml ?? "")

        // Step 4: Set time
        setCurrentTime(currentTime)

        // Step 5: Resume playing state
        setPlaying(isPlaying)
    }

    // MARK: - Memory Cleanup

    /// Clears lyrics-related state to prevent memory accumulation on track change.
    /// This explicitly notifies JS to clean up DOM, animations, and cached data.
    func clearLyricsState() {
        guard !isShutDown, let webView = retainedWebView else { return }

        Log.debug("clearLyricsState: objectID=\(webViewObjectID)", category: .webview)

        // Clear Swift-side state
        lastTTML = nil
        lastTime = nil
        lastIsPlaying = nil
        queuedTimeSync = nil
        isTimeSyncInFlight = false
        lastDeliveredTime = nil

        // Notify JS to clean up internal state
        let jsCleanup = """
            (function() {
                if (window.AMLL && typeof window.AMLL.clearState === 'function') {
                    window.AMLL.clearState();
                    return 'cleared';
                }
                if (window.AMLL && typeof window.AMLL.destroy === 'function') {
                    window.AMLL.destroy();
                    return 'destroyed';
                }
                return 'no-cleanup';
            })()
            """
        webView.evaluateJavaScript(jsCleanup) { result, error in
            if let error = error {
                Log.debug("JS cleanup warning: \(error.localizedDescription)", category: .webview)
            } else if let result = result as? String {
                Log.debug("JS cleanup result: \(result)", category: .webview)
            }
        }

        // Force a layout flush to release any pending layer operations
        webView.setNeedsDisplay(webView.bounds)
    }

    /// Performs full teardown of this WebView instance.
    /// Called when the surface is no longer needed (e.g., exiting fullscreen).
    func teardown() {
        Log.info("teardown: objectID=\(webViewObjectID), role=\(role)", category: .webview)

        // Cancel pending operations
        pendingApplyTrack?.cancel()
        pendingApplyTrack = nil
        pendingVisibleLayerProbe?.cancel()
        pendingVisibleLayerProbe = nil
        pendingCalls.removeAll()

        // Clear all state
        lastTTML = nil
        lastTime = nil
        lastIsPlaying = nil
        lastConfigJSON = nil
        lastThemeConfigPatchJSON = nil
        lastThemeCSSScript = nil
        baseThemePalette = nil
        overrideThemePalette = nil
        lastDeliveredTime = nil
        queuedTimeSync = nil
        isTimeSyncInFlight = false
        contentLoadRevision = 0
        onUserSeek = nil

        // Detach from view hierarchy
        activeAttachmentID = nil
        isAttached = false
        isReady = false

        // Notify JS to clean up with more thorough cleanup
        if let webView = retainedWebView {
            let jsTeardown = """
                (function() {
                    // Stop any ongoing animations
                    if (window.AMLL && typeof window.AMLL.setPlaying === 'function') {
                        window.AMLL.setPlaying(false);
                    }
                    // Clear lyrics
                    if (window.AMLL && typeof window.AMLL.setLyricsTTML === 'function') {
                        window.AMLL.setLyricsTTML('');
                    }
                    // Call destroy if available
                    if (window.AMLL && typeof window.AMLL.destroy === 'function') {
                        window.AMLL.destroy();
                        return 'destroyed';
                    }
                    return 'no-destroy';
                })()
                """
            webView.evaluateJavaScript(jsTeardown) { result, error in
                if let error = error {
                    Log.debug("JS teardown warning: \(error.localizedDescription)", category: .webview)
                } else if let result = result as? String {
                    Log.debug("JS teardown result: \(result)", category: .webview)
                }
            }
        }
    }

    // MARK: - Theme Application

    /// Apply a unified theme palette to the WebView.
    /// Sets config theme and injects CSS variables for deep styling.
    func applyTheme(_ palette: ThemePalette) {
        baseThemePalette = palette
        applyEffectiveTheme()
    }

    /// Override the palette used by AMLL without discarding the base theme.
    /// This lets fullscreen keep a dark-style lyrics palette while the app theme continues updating.
    func setThemePaletteOverride(_ palette: ThemePalette?) {
        overrideThemePalette = palette
        applyEffectiveTheme()
    }

    private func applyEffectiveTheme() {
        guard let palette = overrideThemePalette ?? baseThemePalette else {
            return
        }

        let themeName = (palette.scheme == .dark) ? "dark" : "light"
        Log.debug("applyTheme: theme=\(themeName), override=\(overrideThemePalette != nil), objectID=\(webViewObjectID)", category: .webview)

        // 1. Update config JSON (bridge-level metadata)
        let config: [String: Any] = [
            "theme": themeName,
            "textColor": palette.text,
            "shadowColor": palette.shadow,
        ]

        if let data = try? JSONSerialization.data(withJSONObject: config),
            let json = String(data: data, encoding: .utf8)
        {
            lastThemeConfigPatchJSON = json
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
        lastThemeCSSScript = css

        if let themeConfig = lastThemeConfigPatchJSON {
            callJS("window.AMLL.setConfig(\(themeConfig))")
        }
        callJS(css)
    }

    // MARK: - Helpers

    private func logTTMLDiagnostics(_ ttml: String, stage: String) {
        guard Self.ttmlDiagnosticsEnabled else { return }
        let sha = sha256Hex(ttml)
        Log.trace("[TTML][\(stage)] sha256=\(sha), utf8=\(ttml.utf8.count), chars=\(ttml.count)", category: .webview)
        Log.trace("[TTML][\(stage)] head200=\(escapedLogSnippet(String(ttml.prefix(200))))", category: .webview)
        Log.trace("[TTML][\(stage)] tail200=\(escapedLogSnippet(String(ttml.suffix(200))))", category: .webview)

        let xbgPattern = "ttm:role=\"x-bg\""
        guard let roleRange = ttml.range(of: xbgPattern) ?? ttml.range(of: "role=\"x-bg\"") else {
            Log.trace("[TTML][\(stage)] x-bg not found", category: .webview)
            return
        }
        let start = ttml.index(roleRange.lowerBound, offsetBy: -200, limitedBy: ttml.startIndex)
            ?? ttml.startIndex
        let end = ttml.index(roleRange.upperBound, offsetBy: 200, limitedBy: ttml.endIndex)
            ?? ttml.endIndex
        let slice = String(ttml[start..<end])
        Log.trace("[TTML][\(stage)] xbgWindow=\(escapedLogSnippet(slice))", category: .webview)
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

    private func registerMessageHandlers() {
        guard !didRegisterMessageHandlers else { return }
        let contentController = ensureWebView().configuration.userContentController
        contentController.add(self, name: "onReady")
        contentController.add(self, name: "onUserSeek")
        contentController.add(self, name: "log")
        didRegisterMessageHandlers = true
    }

    private func ensureWebView() -> WKWebView {
        if let retainedWebView {
            return retainedWebView
        }

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        if let roleData = try? JSONEncoder().encode(role),
            let roleJSONString = String(data: roleData, encoding: .utf8)
        {
            let roleUserScript = WKUserScript(
                source: "window.__AMLL_SURFACE_ROLE = \(roleJSONString);",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(roleUserScript)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        retainedWebView = webView
        registerMessageHandlers()
        print("[LyricsStore:\(role)] Created WebView instance: objectID=\(webViewObjectID)")
        loadAMLLContent()
        return webView
    }

    private func resolvedAMLLLoadURL(from indexURL: URL) -> URL {
        guard var components = URLComponents(url: indexURL, resolvingAgainstBaseURL: false) else {
            return indexURL
        }

        components.queryItems = [
            URLQueryItem(name: "surface", value: role),
            URLQueryItem(name: "rev", value: "\(contentLoadRevision)"),
        ]
        return components.url ?? indexURL
    }

    private func rebuildWebViewForFreshContent() {
        contentLoadRevision &+= 1

        guard let oldWebView = retainedWebView else {
            loadAMLLContent()
            return
        }

        let hostView = oldWebView.superview
        let frame = oldWebView.frame
        let autoresizingMask = oldWebView.autoresizingMask
        let appearance = oldWebView.appearance
        let navigationDelegate = oldWebView.navigationDelegate
        let isHidden = oldWebView.isHidden

        if didRegisterMessageHandlers {
            let contentController = oldWebView.configuration.userContentController
            contentController.removeScriptMessageHandler(forName: "onReady")
            contentController.removeScriptMessageHandler(forName: "onUserSeek")
            contentController.removeScriptMessageHandler(forName: "log")
            didRegisterMessageHandlers = false
        }

        oldWebView.stopLoading()
        oldWebView.navigationDelegate = nil
        oldWebView.removeFromSuperview()
        retainedWebView = nil

        let newWebView = ensureWebView()
        newWebView.frame = frame
        newWebView.autoresizingMask = autoresizingMask
        newWebView.appearance = appearance
        newWebView.isHidden = isHidden
        if let navigationDelegate {
            newWebView.navigationDelegate = navigationDelegate
        }

        if let hostView {
            hostView.addSubview(newWebView)
        }

        Log.debug("Recreated WebView for fresh AMLL bundle: role=\(role), objectID=\(webViewObjectID), rev=\(contentLoadRevision)", category: .webview)
    }

    private func scheduleTimeSync(_ seconds: Double) {
        if isTimeSyncInFlight {
            queuedTimeSync = seconds
            return
        }
        dispatchTimeSync(seconds)
    }

    private func dispatchTimeSync(_ seconds: Double) {
        guard isReady else { return }
        if let lastDeliveredTime, abs(seconds - lastDeliveredTime) < 0.01 {
            return
        }

        isTimeSyncInFlight = true
        lastDeliveredTime = seconds
        let js = "window.AMLL.setCurrentTime(\(seconds))"
        webView.evaluateJavaScript(js) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    Log.debug("setCurrentTime error: \(error.localizedDescription)", category: .webview)
                }

                self.isTimeSyncInFlight = false

                guard let nextTime = self.queuedTimeSync else { return }
                self.queuedTimeSync = nil

                if let delivered = self.lastDeliveredTime, abs(nextTime - delivered) < 0.01 {
                    return
                }

                self.dispatchTimeSync(nextTime)
            }
        }
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
                print("[AMLLWeb:\(role)] \(message.body)")
            default:
                Log.debug("Unknown message: \(message.name)", category: .webview)
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
