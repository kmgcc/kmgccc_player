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
        context.coordinator.attachWebView(to: hostView)

        print(
            "[AMLLWebView] makeNSView: objectID=\(store.webViewObjectID), attachmentID=\(context.coordinator.attachmentID?.uuidString.prefix(8) ?? "nil")"
        )

        return hostView
    }

    func updateNSView(_ nsView: WebViewHostView, context: Context) {
        context.coordinator.attachWebView(to: nsView)

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
            print("[AMLLWebView] Updated nsView.appearance to match mode: \(mode)")
        }

        if context.coordinator.lastLoggedReady != store.isReady {
            context.coordinator.lastLoggedReady = store.isReady
            print(
                "[AMLLWebView] updateNSView: objectID=\(store.webViewObjectID), isReady=\(store.isReady)"
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    static func dismantleNSView(_ nsView: WebViewHostView, coordinator: Coordinator) {
        guard let attachmentID = coordinator.attachmentID else {
            print("[AMLLWebView] dismantleNSView: no attachmentID")
            return
        }

        let store = coordinator.store
        print(
            "[AMLLWebView] dismantleNSView: objectID=\(store.webViewObjectID), attachmentID=\(attachmentID.uuidString.prefix(8))"
        )
        coordinator.detachWebView(from: nsView)
        store.detach(requestingID: attachmentID)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate {

        let store: LyricsWebViewStore
        var attachmentID: UUID?
        var lastLoggedReady: Bool = false
        private weak var hostView: WebViewHostView?

        init(store: LyricsWebViewStore) {
            self.store = store
        }

        func attachWebView(to hostView: WebViewHostView) {
            if attachmentID == nil || store.activeAttachmentID != attachmentID {
                attachmentID = store.attach()
            }

            let webView = store.webView
            if webView.navigationDelegate !== self {
                webView.navigationDelegate = self
            }

            guard webView.superview !== hostView else {
                self.hostView = hostView
                return
            }

            webView.removeFromSuperview()
            webView.frame = hostView.bounds
            webView.autoresizingMask = [.width, .height]
            hostView.addSubview(webView)
            self.hostView = hostView

            print(
                "[AMLLWebView] Reparented WebView: objectID=\(store.webViewObjectID), attachmentID=\(attachmentID?.uuidString.prefix(8) ?? "nil")"
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
            print("[AMLLWebView] Navigation finished: objectID=\(store.webViewObjectID)")
        }

        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
            print("[AMLLWebView] Navigation failed: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation: WKNavigation!,
            withError error: Error
        ) {
            print("[AMLLWebView] Provisional navigation failed: \(error.localizedDescription)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            print(
                "[AMLLWebView] ⚠️ Web Content Process Terminated! objectID=\(store.webViewObjectID)")
            store.handleWebContentTerminated()
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
                url.scheme == "http" || url.scheme == "https"
            {
                print("[AMLLWebView] Blocked external navigation: \(url)")
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
