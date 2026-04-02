//
//  AMLLWebView.swift
//  myPlayer2
//
//  kmgccc_player - AMLL WKWebView Wrapper
//  NSViewRepresentable wrapper that hosts a store-owned WebView inside per-view containers.
//  The WebView is NEVER recreated - only reparented between containers.
//

import AppKit
import SwiftUI
import WebKit

/// SwiftUI wrapper for AMLL lyrics WKWebView.
/// Uses a LyricsWebViewStore to prevent WebView recreation.
struct AMLLWebView: NSViewRepresentable {

    let store: LyricsWebViewStore
    @Environment(AppSettings.self) private var settings
    var forcedAppearanceMode: AppSettings.AppearanceMode?

    @MainActor
    init(forcedAppearanceMode: AppSettings.AppearanceMode? = nil) {
        self.store = .shared
        self.forcedAppearanceMode = forcedAppearanceMode
    }

    @MainActor
    init(
        store: LyricsWebViewStore,
        forcedAppearanceMode: AppSettings.AppearanceMode? = nil
    ) {
        self.store = store
        self.forcedAppearanceMode = forcedAppearanceMode
    }

    func makeNSView(context: Context) -> WebViewHostView {
        let hostView = WebViewHostView()

        Log.debug(
            "makeNSView: objectID=\(store.webViewObjectID)",
            category: .webview
        )

        // Try initial attach - may be deferred if frame is zero
        context.coordinator.tryAttach(to: hostView, context: "makeNSView")

        return hostView
    }

    func updateNSView(_ nsView: WebViewHostView, context: Context) {
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
        Coordinator(store: store)
    }

    static func dismantleNSView(_ nsView: WebViewHostView, coordinator: Coordinator) {
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
        var attachmentID: UUID?
        var lastLoggedReady: Bool = false
        var lastLoggedAppearanceMode: AppSettings.AppearanceMode?
        private weak var hostView: WebViewHostView?
        private var hasAttemptedAttach = false

        init(store: LyricsWebViewStore) {
            self.store = store
        }

        /// Try to attach WebView to host, with detailed logging
        func tryAttach(to hostView: WebViewHostView, context: String) {
            // Check conditions but don't block - just log
            let hasWindow = hostView.window != nil
            let hasFrame = hostView.frame.size.width > 0 && hostView.frame.size.height > 0
            let isAttached = store.preparedWebView?.superview === hostView

            Log.debug("tryAttach [\(context)]: hasWindow=\(hasWindow), hasFrame=\(hasFrame), isAttached=\(isAttached), hostFrame=\(hostView.bounds)", category: .webview)

            // If already attached to this host, just ensure frame is correct
            if isAttached {
                if let webView = store.preparedWebView, webView.frame != hostView.bounds {
                    webView.frame = hostView.bounds
                    Log.debug("Updated WebView frame: \(webView.frame)", category: .webview)
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
                Log.debug("Removing WebView from old superview", category: .webview)
                webView.removeFromSuperview()
            }

            // Add to new host
            webView.frame = hostView.bounds
            webView.autoresizingMask = [.width, .height]
            hostView.addSubview(webView)
            self.hostView = hostView

            Log.debug(
                "Reparented WebView: objectID=\(store.webViewObjectID), attachmentID=\(attachmentID?.uuidString.prefix(8) ?? "nil"), frame=\(webView.frame), window=\(webView.window != nil)",
                category: .webview
            )
        }

        func detachWebView(from hostView: WebViewHostView) {
            let webView = store.webView
            guard webView.superview === hostView else { return }
            webView.removeFromSuperview()
            if self.hostView === hostView {
                self.hostView = nil
            }
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
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
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
    override var isFlipped: Bool { true }
}

// MARK: - Preview

#Preview("AMLL WebView") {
    AMLLWebView()
        .frame(width: 400, height: 500)
        .background(Color.black.opacity(0.8))
}
