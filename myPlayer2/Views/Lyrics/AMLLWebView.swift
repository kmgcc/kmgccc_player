//
//  AMLLWebView.swift
//  myPlayer2
//
//  kmgccc_player - AMLL WKWebView Wrapper
//  NSViewRepresentable wrapper that hosts a store-owned WebView inside per-view containers.
//  The WebView is NEVER recreated - only reparented between containers.
//

import AppKit
import QuartzCore
import SwiftUI
import WebKit

/// SwiftUI wrapper for AMLL lyrics WKWebView.
/// Uses a LyricsWebViewStore to prevent WebView recreation.
struct AMLLWebView: NSViewRepresentable {

    let store: LyricsWebViewStore
    @Environment(AppSettings.self) private var settings
    var forcedAppearanceMode: AppSettings.AppearanceMode?
    var animatesAttachment: Bool

    @MainActor
    init(
        forcedAppearanceMode: AppSettings.AppearanceMode? = nil,
        animatesAttachment: Bool = false
    ) {
        self.store = .shared
        self.forcedAppearanceMode = forcedAppearanceMode
        self.animatesAttachment = animatesAttachment
    }

    @MainActor
    init(
        store: LyricsWebViewStore,
        forcedAppearanceMode: AppSettings.AppearanceMode? = nil,
        animatesAttachment: Bool = false
    ) {
        self.store = store
        self.forcedAppearanceMode = forcedAppearanceMode
        self.animatesAttachment = animatesAttachment
    }

    func makeNSView(context: Context) -> WebViewHostView {
        LyricsRuntimeProfile.increment("AMLLWebView.makeNSView")
        let hostView = WebViewHostView()
        context.coordinator.updateRenderQualityScale(
            effectiveRenderQualityScale,
            reason: "makeNSView"
        )

        Log.debug(
            "makeNSView: objectID=\(store.webViewObjectID)",
            category: .webview
        )

        // Try initial attach - may be deferred if frame is zero
        context.coordinator.tryAttach(to: hostView, context: "makeNSView")

        return hostView
    }

    func updateNSView(_ nsView: WebViewHostView, context: Context) {
        LyricsRuntimeProfile.increment("AMLLWebView.updateNSView")
        context.coordinator.updateRenderQualityScale(
            effectiveRenderQualityScale,
            reason: "updateNSView"
        )
        // Always try to ensure WebView is attached with correct frame
        context.coordinator.tryAttach(to: nsView, context: "updateNSView")

        // Handle appearance sync for AppKit side
        let mode = forcedAppearanceMode ?? settings.appearanceMode
        let appearanceIcon: NSAppearance? = {
            switch mode {
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            case .system: return nil  // Follow window/system
            }
        }()

        guard let webView = store.preparedWebView else { return }
        if webView.appearance != appearanceIcon {
            webView.appearance = appearanceIcon
        }

        LyricsRuntimeProfile.recordFlagChange(
            key: "WebViewHostView.isHidden",
            previous: context.coordinator.lastHostHidden,
            next: nsView.isHidden
        )
        context.coordinator.lastHostHidden = nsView.isHidden
        LyricsRuntimeProfile.recordFlagChange(
            key: "WKWebView.isHidden",
            previous: context.coordinator.lastWebViewHidden,
            next: webView.isHidden
        )
        context.coordinator.lastWebViewHidden = webView.isHidden
        if let lastAlphaValue = context.coordinator.lastWebViewAlphaValue {
            if abs(lastAlphaValue - Double(webView.alphaValue)) >= 0.001 {
                LyricsRuntimeProfile.increment("WKWebView.alphaValue.changed")
                LyricsRuntimeProfile.setMetadata(
                    "WKWebView.alphaValue.last",
                    value: String(format: "%.3f", webView.alphaValue)
                )
            } else {
                LyricsRuntimeProfile.increment("WKWebView.alphaValue.same")
            }
        }
        context.coordinator.lastWebViewAlphaValue = Double(webView.alphaValue)

        if context.coordinator.lastLoggedAppearanceMode != mode {
            context.coordinator.lastLoggedAppearanceMode = mode
            Log.debug(
                "updateNSView: appearanceMode=\(mode), objectID=\(store.webViewObjectID)",
                category: .webview
            )
        }

        if context.coordinator.lastLoggedReady != store.isReady {
            context.coordinator.lastLoggedReady = store.isReady
            Log.debug(
                "updateNSView: objectID=\(store.webViewObjectID), isReady=\(store.isReady)",
                category: .webview
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, animatesAttachment: animatesAttachment)
    }

    private var effectiveRenderQualityScale: Double {
        guard let role = LyricsSurfaceRole(rawValue: store.role) else {
            return settings.amllLyricsRenderQualityScale
        }
        return role.supportsAMLLRenderQuality ? settings.amllLyricsRenderQualityScale : 1
    }

    static func dismantleNSView(_ nsView: WebViewHostView, coordinator: Coordinator) {
        LyricsRuntimeProfile.increment("AMLLWebView.dismantleNSView")
        guard let attachmentID = coordinator.attachmentID else {
            Log.debug("dismantleNSView: no attachmentID", category: .webview)
            return
        }

        let store = coordinator.store
        Log.debug(
            "dismantleNSView: objectID=\(store.webViewObjectID), attachmentID=\(attachmentID.uuidString.prefix(8))",
            category: .webview
        )
        coordinator.detachWebView(from: nsView)
        store.detach(requestingID: attachmentID)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate {

        let store: LyricsWebViewStore
        let animatesAttachment: Bool
        var attachmentID: UUID?
        var lastLoggedReady: Bool = false
        var lastLoggedAppearanceMode: AppSettings.AppearanceMode?
        var lastHostHidden = false
        var lastWebViewHidden = false
        var lastWebViewAlphaValue: Double?
        private weak var hostView: WebViewHostView?
        private var hasAttemptedAttach = false
        private var renderQualityScale: CGFloat = 1

        init(store: LyricsWebViewStore, animatesAttachment: Bool) {
            self.store = store
            self.animatesAttachment = animatesAttachment
        }

        func updateRenderQualityScale(_ scale: Double, reason: String) {
            renderQualityScale = CGFloat(max(0.1, min(1, scale)))
            hostView?.webViewLayoutScale = renderQualityScale
            store.setRenderQualityScale(renderQualityScale, reason: reason)
        }

        /// Try to attach WebView to host, with detailed logging
        func tryAttach(to hostView: WebViewHostView, context: String) {
            LyricsRuntimeProfile.increment("AMLLWebView.tryAttach")
            // Check conditions but don't block - just log
            let hasWindow = hostView.window != nil
            let hasFrame = hostView.frame.size.width > 0 && hostView.frame.size.height > 0
            let isAttached = store.preparedWebView?.superview === hostView

            Log.debug("tryAttach [\(context)]: hasWindow=\(hasWindow), hasFrame=\(hasFrame), isAttached=\(isAttached), hostFrame=\(hostView.bounds)", category: .webview)
            if EmbeddedFullscreenTrace.enabled, store.role == LyricsSurfaceRole.fullscreen.rawValue {
                let isSystemFullscreen = hostView.window?.styleMask.contains(.fullScreen) == true
                Log.info(
                    "[EFS t=\(EmbeddedFullscreenTrace.stamp())] AMLL.tryAttach ctx=\(context) role=\(store.role) hasWindow=\(hasWindow) hasFrame=\(hasFrame) isAttached=\(isAttached) hostBounds=\(hostView.bounds.size) isSystemFullscreen=\(isSystemFullscreen)",
                    category: .webview
                )
            }

            // If already attached to this host, just ensure frame is correct
            if isAttached {
                if let webView = store.preparedWebView {
                    store.layoutPreparedWebView(in: hostView.bounds, reason: "tryAttach:\(context)")
                    LyricsRuntimeProfile.recordFrameWrite(
                        key: "WKWebView.frame",
                        previous: webView.frame,
                        next: webView.frame
                    )
                }
                self.hostView = hostView
                return
            }

            // Proceed with attach regardless of window/frame state
            // The WebView will be attached, and frame will be updated later when layout happens
            attachWebView(to: hostView)
            hasAttemptedAttach = true
        }

        func attachWebView(to hostView: WebViewHostView) {
            LyricsRuntimeProfile.increment("AMLLWebView.attachWebView")
            let shouldAnimateAttachment = animatesAttachment
                && store.preparedWebView?.superview !== hostView
            if attachmentID == nil || store.activeAttachmentID != attachmentID {
                attachmentID = store.attach()
                Log.debug("Attached store, attachmentID=\(attachmentID?.uuidString.prefix(8) ?? "nil")", category: .webview)
            }

            let webView = store.webView
            if webView.navigationDelegate !== self {
                webView.navigationDelegate = self
            }

            // Remove from old superview if different
            if let superview = webView.superview, superview !== hostView {
                LyricsRuntimeProfile.increment("AMLLWebView.reparentFromOldSuperview")
                Log.debug("Removing WebView from old superview", category: .webview)
                webView.removeFromSuperview()
            }

            // Add to new host
            hostView.webViewLayoutScale = renderQualityScale
            store.layoutPreparedWebView(in: hostView.bounds, reason: "attachWebView")
            hostView.onLayout = { [weak store] bounds in
                store?.layoutPreparedWebView(in: bounds, reason: "hostLayout")
            }
            hostView.addSubview(webView)
            if shouldAnimateAttachment {
                webView.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.24
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    webView.animator().alphaValue = 1
                }
            }
            store.requestLayoutResync(reason: "attachWebView:postAdd")
            store.refreshMouseInteractionSuppression(reason: "attachWebView")
            store.setRenderQualityScale(
                renderQualityScale,
                reason: "attachWebView"
            )
            self.hostView = hostView

            Log.debug(
                "Reparented WebView: objectID=\(store.webViewObjectID), attachmentID=\(attachmentID?.uuidString.prefix(8) ?? "nil"), frame=\(webView.frame), window=\(webView.window != nil)",
                category: .webview
            )
        }

        func detachWebView(from hostView: WebViewHostView) {
            LyricsRuntimeProfile.increment("AMLLWebView.detachWebView")
            guard let webView = store.preparedWebView else { return }
            guard webView.superview === hostView else { return }
            webView.removeFromSuperview()
            if self.hostView === hostView {
                self.hostView = nil
            }
            hostView.onLayout = nil
            hostView.webViewLayoutScale = 1
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Log.debug("Navigation finished: objectID=\(store.webViewObjectID)", category: .webview)
        }

        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
            Log.error("Navigation failed: \(error.localizedDescription)", category: .webview)
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation: WKNavigation!,
            withError error: Error
        ) {
            Log.error("Provisional navigation failed: \(error.localizedDescription)", category: .webview)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Log.warning(
                "Web content process terminated: objectID=\(store.webViewObjectID)",
                category: .webview
            )
            store.handleWebContentTerminated()
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
                url.scheme == "http" || url.scheme == "https"
            {
                Log.warning("Blocked external navigation: \(url)", category: .webview)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

final class WebViewHostView: NSView {
    var onLayout: ((CGRect) -> Void)?
    var webViewLayoutScale: CGFloat = 1

    var isMouseInteractionSuppressed = false {
        didSet {
            if oldValue != isMouseInteractionSuppressed {
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WebViewHostView does not support NSCoding")
    }

    override var isFlipped: Bool { true }

    /// At q < 1, WKWebView's real NSView frame is `host × q` and is visually
    /// expanded by a layer transform. AppKit hit-testing still uses the small
    /// pre-transform frame, so the lower/right visual area would miss WebKit.
    /// Return the WKWebView itself for the full host bounds so events enter
    /// `LyricsMouseGatedWebView` and keep the native WebKit click pipeline.
    ///
    /// Do not call `webView.hitTest` here: that can target WKWebView internal
    /// subviews directly and bypass the scaled event adapter.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isMouseInteractionSuppressed else { return nil }
        if webViewLayoutScale < 0.999,
           bounds.contains(point),
           let webView = subviews.first(where: { $0 is WKWebView }) {
            return webView
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        // Consume only if a transient no-WebView state still targets the host.
    }

    override func mouseUp(with event: NSEvent) {
        // Consume; suppress NSResponder default forward to home view.
    }

    override func mouseDragged(with event: NSEvent) {
        // Consume.
    }

    override func rightMouseDown(with event: NSEvent) {
        // Consume; no context menu on the lyric card.
    }

    override func rightMouseUp(with event: NSEvent) {
        // Consume.
    }

    override func rightMouseDragged(with event: NSEvent) {
        // Consume.
    }

    override func otherMouseDown(with event: NSEvent) {
        // Consume.
    }

    override func otherMouseUp(with event: NSEvent) {
        // Consume.
    }

    override func otherMouseDragged(with event: NSEvent) {
        // Consume.
    }

    override func scrollWheel(with event: NSEvent) {
        // Consume only if a transient no-WebView state still targets the host.
        // When hit-testing reaches the hosted WKWebView, q >= 1 uses WebKit's
        // native wheel path and q < 1 is bridged by LyricsMouseGatedWebView
        // into AMLL's existing DOM wheel listener.
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previousFrame = frame
        super.setFrameSize(newSize)
        LyricsRuntimeProfile.recordFrameWrite(
            key: "WebViewHostView.frame",
            previous: previousFrame,
            next: frame
        )
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let previousFrame = frame
        super.setFrameOrigin(newOrigin)
        LyricsRuntimeProfile.recordFrameWrite(
            key: "WebViewHostView.frame",
            previous: previousFrame,
            next: frame
        )
    }

    override func layout() {
        LyricsRuntimeProfile.increment("WebViewHostView.layout")
        super.layout()
        onLayout?(bounds)
    }

    override func layoutSubtreeIfNeeded() {
        LyricsRuntimeProfile.increment("WebViewHostView.layoutSubtreeIfNeeded")
        super.layoutSubtreeIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        LyricsRuntimeProfile.increment("WebViewHostView.viewDidMoveToWindow")
        LyricsRuntimeProfile.setMetadata(
            "WebViewHostView.windowAttached",
            value: window != nil ? "true" : "false"
        )
    }
}

// MARK: - Preview

#Preview("AMLL WebView") {
    AMLLWebView()
        .frame(width: 400, height: 500)
        .background(Color.black.opacity(0.8))
}
