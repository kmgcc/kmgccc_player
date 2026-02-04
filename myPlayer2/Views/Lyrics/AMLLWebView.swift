//
//  AMLLWebView.swift
//  myPlayer2
//
//  TrueMusic - AMLL WKWebView Wrapper
//  NSViewRepresentable wrapper for embedding lyrics WebView in SwiftUI.
//

import SwiftUI
import WebKit

/// SwiftUI wrapper for AMLL lyrics WKWebView.
struct AMLLWebView: NSViewRepresentable {

    /// Lyrics bridge for Swift <-> JS communication.
    let bridge: LyricsBridge

    /// Bundle to load AMLL resources from (default is .main).
    var resourceBundle: Bundle = .main

    func makeNSView(context: Context) -> WKWebView {
        // Configure WebView
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Allow file access is critical for local resources
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // Transparent background
        webView.setValue(false, forKey: "drawsBackground")

        // Attach bridge
        bridge.attachToWebView(webView)

        // Load local HTML
        loadLocalContent(webView)

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No dynamic updates needed - bridge handles state sync
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.bridge?.detach()
        nsView.navigationDelegate = nil
    }

    // MARK: - Load Local Content

    private func loadLocalContent(_ webView: WKWebView) {
        let bundleName = resourceBundle.bundleIdentifier ?? "Unknown Bundle"
        print("[AMLLWebView] Attempting to load AMLL from Bundle: \(bundleName)")

        // Task 3: Load strictly from bundle
        if let indexURL = resourceBundle.url(
            forResource: "index", withExtension: "html", subdirectory: "AMLL")
        {
            print("[AMLLWebView] Resolved indexURL: \(indexURL.path)")

            let amllDir = indexURL.deletingLastPathComponent()

            // Verification Check
            let fileExists = FileManager.default.fileExists(atPath: indexURL.path)
            print("[AMLLWebView] fileExists(indexURL): \(fileExists)")

            // Debug: List directory content
            if fileExists {
                listDirectoryContents(url: amllDir)

                print("[AMLLWebView] Loading file URL...")
                // .readAccessURL must be the directory containing the file
                webView.loadFileURL(indexURL, allowingReadAccessTo: amllDir)
                return
            } else {
                print("[AMLLWebView] Error: Bundle URL resolved but file missing on disk!")
            }
        } else {
            print("[AMLLWebView] Bundle resource 'AMLL/index.html' NOT found in \(bundleName).")
            print(
                "[AMLLWebView] Root Cause: The 'AMLL' folder is likely not added to 'Copy Bundle Resources' in Xcode."
            )

            // Debug: List bundle resources to help diagnosis
            // listBundleResources()
        }

        // Task 1: No filesystem fallback allowed in Sandbox.
        // FAIL LOUD
        loadErrorPage(webView, bundleName: bundleName)
    }

    private func listDirectoryContents(url: URL) {
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: url.path)
            print("[AMLLWebView] AMLL Directory Contents (\(files.count) items):")
            for file in files.prefix(10) {
                print(" - \(file)")
            }
            if files.count > 10 { print(" - ... and \(files.count - 10) more") }
        } catch {
            print("[AMLLWebView] Failed to list directory: \(error)")
        }
    }

    private func loadErrorPage(_ webView: WKWebView, bundleName: String) {
        let html = """
            <!DOCTYPE html>
            <html>
            <body style="background:rgba(0,0,0,0.5); color:#ff5555; font-family:-apple-system,system-ui,sans-serif; padding:20px; text-align:center;">
                <h3 style="margin-bottom:10px">⚠️ AMLL Bundle Missing</h3>
                <p style="font-size:14px; opacity:0.9">The lyrics engine could not be loaded from:</p>
                <code style="display:block; background:rgba(0,0,0,0.3); padding:8px; margin:10px 0; font-size:12px;">\(bundleName)</code>
                
                <div style="background:rgba(0,0,0,0.3); padding:12px; border-radius:8px; margin-top:20px; text-align:left; font-family:monospace; font-size:11px; line-height:1.4;">
                    <strong style="color:#fff">Developer Action Required:</strong><br><br>
                    1. Open Xcode<br>
                    2. Go to Targets -> myPlayer2 -> <strong>Build Phases</strong><br>
                    3. Expand <strong>"Copy Bundle Resources"</strong><br>
                    4. Add the <strong>"AMLL"</strong> folder<br>
                       (Choose "Create folder references" for blue folder icon)<br><br>
                    <em>Ensure index.html is at AMLL/index.html inside the bundle.</em>
                </div>
            </body>
            </html>
            """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate {

        weak var bridge: LyricsBridge?

        init(bridge: LyricsBridge) {
            self.bridge = bridge
            super.init()
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Block external navigation
            if let url = navigationAction.request.url {
                if url.scheme == "http" || url.scheme == "https" {
                    print("[AMLLWebView] Blocked external navigation: \(url)")
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[AMLLWebView] Page loaded successfully (or error page)")
        }

        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
            print("[AMLLWebView] Navigation failed: \(error.localizedDescription)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            print("[AMLLWebView] ⚠️ Web Content Process Terminated. Reloading...")
            // Reloading the page usually restarts the process
            webView.reload()
        }
    }
}

// MARK: - Preview

#Preview("AMLL WebView") {
    let bridge = LyricsBridge()

    AMLLWebView(bridge: bridge)
        .frame(width: 400, height: 500)
        .background(Color.black.opacity(0.8))
}
