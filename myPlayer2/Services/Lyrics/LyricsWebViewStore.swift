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

    private enum JavaScriptCall {
        case script(String)
        case function(body: String, arguments: [String: Any])
    }

    private struct PendingJavaScriptCall {
        let debugDescription: String
        let call: JavaScriptCall
    }

    // MARK: - Singleton

    static let shared = LyricsWebViewStore()
    private nonisolated static let ttmlDiagnosticsEnabled =
        ProcessInfo.processInfo.environment["AMLL_TTML_DIAGNOSTICS"] == "1"
    private nonisolated static let visibleLayerProbeEnabled =
        ProcessInfo.processInfo.environment["KMGCCC_AMLL_VISIBLE_LAYER_PROBE"] == "1"
    private nonisolated static let automaticRecycleTrackThreshold: Int = {
        guard
            let rawValue = ProcessInfo.processInfo.environment["KMGCCC_AMLL_WEBVIEW_RECYCLE_TRACKS"],
            let parsedValue = Int(rawValue),
            parsedValue > 0
        else {
            return 10
        }
        return parsedValue
    }()

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
    private var lastTrackID: UUID?
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
    private var pendingCalls: [PendingJavaScriptCall] = []

    /// Recovery state.
    private var isRecoveryInProgress: Bool = false
    private var lastRecoveryAttempt: Date = .distantPast
    private let recoveryDebounceInterval: TimeInterval = 1.0
    private var contentLoadRevision: Int = 0
    private var trackSwitchesSinceLastWebViewRecycle: Int = 0

    /// Track change debounce (prevents transient nil clearing).
    private var pendingApplyTrack: DispatchWorkItem?
    private var pendingVisibleLayerProbe: DispatchWorkItem?
    private var pendingTrackDiagnosticsProbe: DispatchWorkItem?
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

    /// Eagerly materialize the WKWebView so surface switching can wait on a real ready event.
    func prepareWebViewIfNeeded() {
        guard !isShutDown else { return }
        _ = ensureWebView()
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true

        // Cancel all pending operations
        pendingApplyTrack?.cancel()
        pendingApplyTrack = nil
        pendingVisibleLayerProbe?.cancel()
        pendingVisibleLayerProbe = nil
        pendingTrackDiagnosticsProbe?.cancel()
        pendingTrackDiagnosticsProbe = nil
        pendingCalls.removeAll()
        onUserSeek = nil

        // Clear all state
        activeAttachmentID = nil
        isAttached = false
        isReady = false
        isRecoveryInProgress = false
        lastTTML = nil
        lastTrackID = nil
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
        trackSwitchesSinceLastWebViewRecycle = 0
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
        callJSFunction(
            body: "window.AMLL.setLyricsTTML(ttmlText)",
            arguments: ["ttmlText": ttml],
            debugDescription: "window.AMLL.setLyricsTTML(len=\(ttml.count))"
        )
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
        callJS("window.AMLL.setPlaying(\(boolStr))", debugDescription: "window.AMLL.setPlaying")
    }

    func setConfigJSON(_ json: String) {
        guard !isShutDown else { return }

        // Deduplication: skip if same config
        if json == lastConfigJSON {
            return
        }

        lastConfigJSON = json
        callConfigJSON(json, reason: "setConfigJSON")
    }

    /// Force set config JSON bypassing deduplication.
    /// Use when appearance/colorScheme changes require guaranteed delivery.
    func forceSetConfigJSON(_ json: String, reason: String) {
        guard !isShutDown else { return }

        Log.debug("forceSetConfigJSON: reason=\(reason), webViewObjectID=\(webViewObjectID), jsonChanged=\(json != lastConfigJSON)", category: .webview)

        lastConfigJSON = json
        callConfigJSON(json, reason: "forceSetConfigJSON:\(reason)")
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
    private func callJS(_ script: String, debugDescription: String? = nil) {
        enqueueJavaScriptCall(
            .script(script),
            debugDescription: debugDescription
                ?? (script.count > 100 ? String(script.prefix(100)) + "..." : script)
        )
    }

    private func callJSFunction(
        body: String,
        arguments: [String: Any],
        debugDescription: String
    ) {
        enqueueJavaScriptCall(
            .function(body: body, arguments: arguments),
            debugDescription: debugDescription
        )
    }

    private func callConfigJSON(_ json: String, reason: String) {
        guard let object = decodeJSONObject(json) else {
            Log.warning("Config JSON decode failed, falling back to script bridge, reason=\(reason)", category: .webview)
            callJS("window.AMLL.setConfig(\(json))", debugDescription: "window.AMLL.setConfig(fallback)")
            return
        }
        callJSFunction(
            body: "window.AMLL.setConfig(config)",
            arguments: ["config": object],
            debugDescription: "window.AMLL.setConfig(\(reason))"
        )
    }

    private func enqueueJavaScriptCall(
        _ call: JavaScriptCall,
        debugDescription: String
    ) {
        guard !isShutDown else { return }
        let pendingCall = PendingJavaScriptCall(
            debugDescription: debugDescription,
            call: call
        )
        if isReady {
            executeJavaScriptCall(pendingCall)
        } else {
            pendingCalls.append(pendingCall)
            Log.debug(
                "Queued JS call: \(debugDescription), pending=\(pendingCalls.count), objectID=\(webViewObjectID)",
                category: .webview
            )
        }
    }

    private func executeJavaScriptCall(
        _ pendingCall: PendingJavaScriptCall,
        completion: ((Any?, Error?) -> Void)? = nil
    ) {
        let finish: @MainActor @Sendable (Any?, Error?) -> Void = { result, error in
            if let error {
                Log.debug(
                    "JS error: \(error.localizedDescription), call: \(pendingCall.debugDescription)",
                    category: .webview
                )
            }
            completion?(result, error)
        }

        switch pendingCall.call {
        case .script(let script):
            webView.evaluateJavaScript(script) { result, error in
                finish(result, error)
            }
        case .function(let body, let arguments):
            webView.callAsyncJavaScript(
                body,
                arguments: arguments,
                in: nil,
                in: .page,
                completionHandler: { result in
                    switch result {
                    case .success(let value):
                        finish(value, nil)
                    case .failure(let error):
                        finish(nil, error)
                    }
                }
            )
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
        scheduleTrackDiagnostics(
            stage: "onReady",
            trackID: lastTrackID,
            ttmlLength: lastTTML?.count ?? 0,
            delay: 0.2
        )

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
        for pendingCall in pendingCalls {
            executeJavaScriptCall(pendingCall) { _, error in
                if let error {
                    Log.debug(
                        "Flush error: \(error.localizedDescription), call=\(pendingCall.debugDescription)",
                        category: .webview
                    )
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
            callConfigJSON(config, reason: "replayStateSnapshot.config")
        }

        if let themeConfig = lastThemeConfigPatchJSON {
            callConfigJSON(themeConfig, reason: "replayStateSnapshot.themeConfig")
        }

        if let themeCSS = lastThemeCSSScript {
            webView.evaluateJavaScript(themeCSS, completionHandler: nil)
        }

        // Step 2: TTML
        if let ttml = lastTTML {
            logTTMLDiagnostics(ttml, stage: "replayStateSnapshot")
            callJSFunction(
                body: "window.AMLL.setLyricsTTML(ttmlText)",
                arguments: ["ttmlText": ttml],
                debugDescription: "window.AMLL.setLyricsTTML(replay,len=\(ttml.count))"
            )
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
    func applyTrack(
        trackID: UUID? = nil,
        ttml: String?,
        currentTime: Double,
        isPlaying: Bool
    ) {
        // Cancel any pending apply
        pendingApplyTrack?.cancel()

        // Debounce only transitional nil (e.g. oldTrack -> nil -> newTrack)
        if ttml == nil {
            let workItem = DispatchWorkItem { [weak self] in
                self?.executeApplyTrack(
                    trackID: trackID,
                    ttml: ttml,
                    currentTime: currentTime,
                    isPlaying: isPlaying
                )
            }
            pendingApplyTrack = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(applyTrackDebounceMs), execute: workItem)
            Log.debug("applyTrack: debounced nil, objectID=\(webViewObjectID)", category: .webview)
        } else {
            // Immediate apply for concrete payload (including empty string clear)
            executeApplyTrack(
                trackID: trackID,
                ttml: ttml,
                currentTime: currentTime,
                isPlaying: isPlaying
            )
        }
    }

    private func executeApplyTrack(
        trackID: UUID?,
        ttml: String?,
        currentTime: Double,
        isPlaying: Bool
    ) {
        let previousTrackID = lastTrackID
        let didSwitchTracks =
            previousTrackID != nil
            && trackID != nil
            && previousTrackID != trackID

        if didSwitchTracks {
            trackSwitchesSinceLastWebViewRecycle += 1
        }

        if shouldRecycleWebViewBeforeApplyingTrack(
            previousTrackID: previousTrackID,
            nextTrackID: trackID
        ) {
            prepareSnapshotForReload(
                trackID: trackID,
                ttml: ttml ?? "",
                currentTime: currentTime,
                isPlaying: isPlaying
            )
            Log.info(
                "Auto recycling WebView before track apply: role=\(role), objectID=\(webViewObjectID), trackID=\(trackID?.uuidString.prefix(8) ?? "nil"), switchesSinceRecycle=\(trackSwitchesSinceLastWebViewRecycle), threshold=\(Self.automaticRecycleTrackThreshold)",
                category: .webview
            )
            trackSwitchesSinceLastWebViewRecycle = 0
            forceReload(recreateWebView: true)
            scheduleTrackDiagnostics(
                stage: "afterAutoRecycleRequest",
                trackID: trackID,
                ttmlLength: ttml?.count ?? 0,
                delay: 0.45
            )
            return
        }

        lastTrackID = trackID
        Log.debug(
            "applyTrack: trackID=\(trackID?.uuidString.prefix(8) ?? "nil"), ttmlLen=\(ttml?.count ?? 0), time=\(currentTime), playing=\(isPlaying), objectID=\(webViewObjectID)",
            category: .webview
        )
        logTrackDiagnostics(
            stage: "beforeTrackTeardown",
            trackID: trackID,
            ttmlLength: ttml?.count ?? 0
        )

        // Step 1: Clear previous lyrics state to free memory
        clearLyricsState(
            trackID: trackID,
            nextTTMLLength: ttml?.count ?? 0
        ) { [weak self] in
            guard let self else { return }

            // Step 2: Pause
            self.setPlaying(false)

            // Step 3: Set lyrics
            self.setLyricsTTML(ttml ?? "")

            // Step 4: Set time
            self.setCurrentTime(currentTime)

            // Step 5: Resume playing state
            self.setPlaying(isPlaying)
            self.scheduleTrackDiagnostics(
                stage: "afterTrackApply",
                trackID: trackID,
                ttmlLength: ttml?.count ?? 0,
                delay: 0.35
            )
        }
    }

    // MARK: - Memory Cleanup

    /// Clears lyrics-related state to prevent memory accumulation on track change.
    /// This explicitly notifies JS to clean up DOM, animations, and cached data.
    func clearLyricsState(
        trackID: UUID? = nil,
        nextTTMLLength: Int = 0,
        completion: (() -> Void)? = nil
    ) {
        guard !isShutDown else {
            completion?()
            return
        }

        Log.debug(
            "clearLyricsState: trackID=\(trackID?.uuidString.prefix(8) ?? "nil"), nextTTMLLength=\(nextTTMLLength), objectID=\(webViewObjectID)",
            category: .webview
        )
        logTrackDiagnostics(
            stage: "clearLyricsState.beforeJS",
            trackID: trackID,
            ttmlLength: nextTTMLLength
        )

        // Clear Swift-side state
        lastTTML = nil
        lastTrackID = trackID
        lastTime = nil
        lastIsPlaying = nil
        queuedTimeSync = nil
        isTimeSyncInFlight = false
        lastDeliveredTime = nil

        guard let webView = retainedWebView else {
            completion?()
            return
        }

        let jsCleanup = PendingJavaScriptCall(
            debugDescription: "window.AMLL.clearState()",
            call: .script(
                """
                (function() {
                    if (window.AMLL && typeof window.AMLL.clearState === 'function') {
                        return JSON.stringify(window.AMLL.clearState());
                    }
                    if (window.AMLL && typeof window.AMLL.destroy === 'function') {
                        return JSON.stringify(window.AMLL.destroy());
                    }
                    return JSON.stringify({ status: 'no-cleanup' });
                })()
                """
            )
        )
        executeJavaScriptCall(jsCleanup) { [weak self] result, error in
            guard self != nil else { return }
            if let error = error {
                Log.debug("JS cleanup warning: \(error.localizedDescription)", category: .webview)
            }
            completion?()
        }

        // Force a layout flush to release any pending layer operations
        webView.setNeedsDisplay(webView.bounds)
        scheduleTrackDiagnostics(
            stage: "clearLyricsState.afterJS",
            trackID: trackID,
            ttmlLength: nextTTMLLength,
            delay: 0.1
        )
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
        pendingTrackDiagnosticsProbe?.cancel()
        pendingTrackDiagnosticsProbe = nil
        pendingCalls.removeAll()

        // Clear all state
        lastTTML = nil
        lastTrackID = nil
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
        trackSwitchesSinceLastWebViewRecycle = 0
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
            callConfigJSON(themeConfig, reason: "applyEffectiveTheme")
        }
        callJS(css, debugDescription: "applyEffectiveTheme.css")
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

    private func decodeJSONObject(_ json: String) -> Any? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func compactJSONString(from object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: object)
        }
        return string
    }

    private func makeSwiftDiagnosticsPayload(
        stage: String,
        trackID: UUID?,
        ttmlLength: Int
    ) -> [String: Any] {
        [
            "stage": stage,
            "role": role,
            "trackID": trackID?.uuidString ?? "nil",
            "ttmlLength": ttmlLength,
            "webViewObjectID": webViewObjectID,
            "isReady": isReady,
            "isAttached": isAttached,
            "hasPreparedWebView": retainedWebView != nil,
            "pendingBridgeCalls": pendingCalls.count,
            "lastTrackID": lastTrackID?.uuidString ?? "nil",
            "lastTTMLLength": lastTTML?.count ?? 0,
            "lastConfigLength": lastConfigJSON?.count ?? 0,
            "lastThemeConfigPatchLength": lastThemeConfigPatchJSON?.count ?? 0,
            "lastThemeCSSLength": lastThemeCSSScript?.count ?? 0,
            "queuedTimeSync": queuedTimeSync.map { $0 as Any } ?? NSNull(),
            "isTimeSyncInFlight": isTimeSyncInFlight,
            "lastDeliveredTime": lastDeliveredTime.map { $0 as Any } ?? NSNull(),
            "contentLoadRevision": contentLoadRevision,
            "activeAttachmentID": activeAttachmentID?.uuidString ?? "nil",
            "webViewURL": retainedWebView?.url?.absoluteString ?? "nil",
        ]
    }

    private func scheduleTrackDiagnostics(
        stage: String,
        trackID: UUID?,
        ttmlLength: Int,
        delay: TimeInterval
    ) {
        pendingTrackDiagnosticsProbe?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.logTrackDiagnostics(stage: stage, trackID: trackID, ttmlLength: ttmlLength)
        }
        pendingTrackDiagnosticsProbe = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func logTrackDiagnostics(
        stage: String,
        trackID: UUID?,
        ttmlLength: Int
    ) {
        // Diagnostics are verbose - only output when KMGCCC_AMLL_TTML_DIAGNOSTICS=1
        guard Self.ttmlDiagnosticsEnabled else { return }

        let swiftPayload = makeSwiftDiagnosticsPayload(
            stage: stage,
            trackID: trackID,
            ttmlLength: ttmlLength
        )
        Log.debug(
            "[AMLLDiag][Swift] \(compactJSONString(from: swiftPayload))",
            category: .webview
        )

        guard isReady, retainedWebView != nil else { return }
        let label = "\(role).\(stage).\(trackID?.uuidString.prefix(8) ?? "nil")"
        let diagnosticsCall = PendingJavaScriptCall(
            debugDescription: "window.AMLL.collectDiagnostics(\(label))",
            call: .function(
                body: "JSON.stringify(window.AMLL.collectDiagnostics(label))",
                arguments: ["label": label]
            )
        )
        executeJavaScriptCall(diagnosticsCall) { result, error in
            if let error {
                Log.debug(
                    "[AMLLDiag][JS] role=\(self.role) label=\(label) error=\(error.localizedDescription)",
                    category: .webview
                )
                return
            }
            let payload = result as? String ?? String(describing: result ?? "nil")
            Log.debug("[AMLLDiag][JS] \(payload)", category: .webview)
        }
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

    private func shouldRecycleWebViewBeforeApplyingTrack(
        previousTrackID: UUID?,
        nextTrackID: UUID?
    ) -> Bool {
        guard Self.automaticRecycleTrackThreshold > 0 else { return false }
        guard previousTrackID != nil else { return false }
        guard nextTrackID != nil else { return false }
        guard previousTrackID != nextTrackID else { return false }
        guard hasPreparedWebView else { return false }
        return trackSwitchesSinceLastWebViewRecycle >= Self.automaticRecycleTrackThreshold
    }

    private func prepareSnapshotForReload(
        trackID: UUID?,
        ttml: String,
        currentTime: Double,
        isPlaying: Bool
    ) {
        lastTrackID = trackID
        lastTTML = ttml
        lastTime = currentTime.isFinite ? currentTime : nil
        lastIsPlaying = isPlaying
        queuedTimeSync = nil
        isTimeSyncInFlight = false
        lastDeliveredTime = nil
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
