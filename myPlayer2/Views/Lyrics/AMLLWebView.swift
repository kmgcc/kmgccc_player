//
//  AMLLWebView.swift
//  myPlayer2
//
//  TrueMusic - AMLL WKWebView Wrapper
//  NSViewRepresentable wrapper that returns the singleton WebView from LyricsWebViewStore.
//  The WebView is NEVER recreated - only attached/detached.
//

import SwiftUI
import WebKit

/// SwiftUI wrapper for AMLL lyrics WKWebView.
/// Uses the singleton LyricsWebViewStore to prevent WebView recreation.
struct AMLLWebView: NSViewRepresentable {

    @Environment(AppSettings.self) private var settings

    func makeNSView(context: Context) -> WKWebView {
        let store = LyricsWebViewStore.shared
        let webView = store.webView

        // Set navigation delegate for crash handling
        webView.navigationDelegate = context.coordinator

        // Attach only if not already attached
        context.coordinator.attachmentID = store.attach()

        print(
            "[AMLLWebView] makeNSView: objectID=\(store.webViewObjectID), attachmentID=\(context.coordinator.attachmentID?.uuidString.prefix(8) ?? "nil")"
        )

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Handle appearance sync for AppKit side
        let mode = settings.appearanceMode
        let appearanceIcon: NSAppearance? = {
            switch mode {
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            case .system: return nil  // Follow window/system
            }
        }()

        if nsView.appearance != appearanceIcon {
            nsView.appearance = appearanceIcon
            print("[AMLLWebView] Updated nsView.appearance to match mode: \(mode)")
        }

        // Do NOT re-attach here - attach only happens in makeNSView
        // This prevents duplicate attaches from SwiftUI update cycles
        let store = LyricsWebViewStore.shared
        // Only log occasionally to avoid spam (check if ready state changed)
        if context.coordinator.lastLoggedReady != store.isReady {
            context.coordinator.lastLoggedReady = store.isReady
            print(
                "[AMLLWebView] updateNSView: objectID=\(store.webViewObjectID), isReady=\(store.isReady)"
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        guard let attachmentID = coordinator.attachmentID else {
            print("[AMLLWebView] dismantleNSView: no attachmentID")
            return
        }

        let store = LyricsWebViewStore.shared
        print(
            "[AMLLWebView] dismantleNSView: objectID=\(store.webViewObjectID), attachmentID=\(attachmentID.uuidString.prefix(8))"
        )
        store.detach(requestingID: attachmentID)

        // Do NOT nil out navigationDelegate - WebView persists in store
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate {

        var attachmentID: UUID?
        var lastLoggedReady: Bool = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let store = LyricsWebViewStore.shared
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
            let store = LyricsWebViewStore.shared
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

// MARK: - Preview

#Preview("AMLL WebView") {
    AMLLWebView()
        .frame(width: 400, height: 500)
        .background(Color.black.opacity(0.8))
}
