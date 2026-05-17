//
//  AMLLMeshGradientBackgroundView.swift
//  myPlayer2
//
//  Hosts AMLL's official MeshGradientRenderer in an isolated background WKWebView.
//

import AppKit
import SwiftUI
import WebKit

enum AppleMeshBackgroundSpeed: String, CaseIterable, Identifiable {
    case gentle
    case standard
    case active

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gentle: return "柔和"
        case .standard: return "标准"
        case .active: return "活跃"
        }
    }

    var flowSpeed: Double {
        switch self {
        case .gentle: return 0.18
        case .standard: return 0.32
        case .active: return 0.55
        }
    }

    var fps: Int {
        switch self {
        case .gentle, .standard: return 30
        case .active: return 60
        }
    }
}

struct AMLLMeshGradientBackgroundView: NSViewRepresentable {
    struct Configuration: Equatable {
        let artworkData: Data?
        let artworkChecksum: UInt64
        let isPlaying: Bool
        let dynamicBackgroundEnabled: Bool
        let speed: AppleMeshBackgroundSpeed

        var renderScale: Double { 0.6 }
        var flowSpeed: Double { speed.flowSpeed }
        var fps: Int { speed.fps }
    }

    let configuration: Configuration

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        context.coordinator.attach(to: container)
        context.coordinator.update(configuration)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
        context.coordinator.update(configuration)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dispose()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private weak var hostView: NSView?
        private var webView: WKWebView?
        private var isReady = false
        private var lastConfiguration: Configuration?
        private var lastArtworkChecksum: UInt64?
        private var lowFreqConsumerID: UUID?
        private let spectrumService = AudioVisualizationService.shared

        func attach(to hostView: NSView) {
            self.hostView = hostView
            let webView = ensureWebView()
            guard webView.superview !== hostView else {
                webView.frame = hostView.bounds
                return
            }
            webView.removeFromSuperview()
            webView.frame = hostView.bounds
            webView.autoresizingMask = [.width, .height]
            hostView.addSubview(webView)
            Log.debug("AMLL background attached host=\(hostView.bounds) web=\(webView.frame)", category: .webview)
        }

        func update(_ configuration: Configuration) {
            lastConfiguration = configuration
            syncSampling(for: configuration)
            guard isReady else { return }
            applyConfig(configuration)
            applyArtworkIfNeeded(configuration)
            setPlaying(configuration.isPlaying && configuration.dynamicBackgroundEnabled)
        }

        func dispose() {
            stopSampling()
            call("window.AMLLBackground?.dispose?.()", label: "dispose")
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "backgroundReady")
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "backgroundDebug")
            webView?.navigationDelegate = nil
            webView?.removeFromSuperview()
            webView = nil
            hostView = nil
            isReady = false
            lastConfiguration = nil
            lastArtworkChecksum = nil
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "backgroundReady":
                Log.info("AMLL background ready message: \(String(describing: message.body))", category: .webview)
                markReady()
            case "backgroundDebug":
                logBackgroundWebMessage(message.body)
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Log.info("AMLL background navigation finished frame=\(webView.frame)", category: .webview)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Log.error("AMLL background navigation failed: \(error.localizedDescription)", category: .webview)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Log.error("AMLL background provisional navigation failed: \(error.localizedDescription)", category: .webview)
        }

        private func markReady() {
            guard !isReady else { return }
            isReady = true
            if let configuration = lastConfiguration {
                applyConfig(configuration)
                applyArtworkIfNeeded(configuration, force: true)
                setPlaying(configuration.isPlaying && configuration.dynamicBackgroundEnabled)
            }
            collectDiagnostics(label: "ready")
        }

        private func ensureWebView() -> WKWebView {
            if let webView {
                return webView
            }

            let contentController = WKUserContentController()
            contentController.add(self, name: "backgroundReady")
            contentController.add(self, name: "backgroundDebug")

            let config = WKWebViewConfiguration()
            config.userContentController = contentController
            config.suppressesIncrementalRendering = false
            config.preferences.setValue(true, forKey: "developerExtrasEnabled")
            config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = self
            webView.setValue(false, forKey: "drawsBackground")
            webView.allowsMagnification = false
            webView.allowsBackForwardNavigationGestures = false
            webView.isHidden = false

            if let htmlURL = Bundle.main.url(forResource: "background", withExtension: "html", subdirectory: "AMLL"),
               let readAccessURL = Bundle.main.resourceURL?.appendingPathComponent("AMLL", isDirectory: true) {
                Log.info("Loading AMLL background from: \(htmlURL.absoluteString)", category: .webview)
                webView.loadFileURL(htmlURL, allowingReadAccessTo: readAccessURL)
            } else {
                Log.error("AMLL background.html missing from app bundle", category: .webview)
            }

            self.webView = webView
            return webView
        }

        private func applyConfig(_ configuration: Configuration) {
            let payload: [String: Any] = [
                "dynamic": configuration.dynamicBackgroundEnabled,
                "fps": configuration.fps,
                "flowSpeed": configuration.flowSpeed,
                "renderScale": configuration.renderScale,
            ]
            callFunction(
                "window.AMLLBackground?.setConfig",
                arguments: [payload],
                label: "setConfig"
            )
        }

        private func applyArtworkIfNeeded(_ configuration: Configuration, force: Bool = false) {
            guard force || lastArtworkChecksum != configuration.artworkChecksum else { return }
            lastArtworkChecksum = configuration.artworkChecksum
            guard let data = configuration.artworkData, !data.isEmpty else { return }
            let mime = imageMIMEType(for: data)
            let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"
            callFunction(
                "window.AMLLBackground?.setAlbum",
                arguments: [dataURL],
                label: "setAlbum"
            )
            collectDiagnostics(label: "setAlbum")
        }

        private func setPlaying(_ isPlaying: Bool) {
            callFunction(
                "window.AMLLBackground?.setPlaying",
                arguments: [isPlaying],
                label: "setPlaying"
            )
            spectrumService.updatePlaybackState(isPlaying: isPlaying)
        }

        private func syncSampling(for configuration: Configuration) {
            if configuration.dynamicBackgroundEnabled {
                startSampling(isPlaying: configuration.isPlaying)
            } else {
                stopSampling()
                callFunction(
                    "window.AMLLBackground?.setLowFreqVolume",
                    arguments: [0.0],
                    label: "setLowFreqVolumeZero"
                )
            }
        }

        private func startSampling(isPlaying: Bool) {
            if lowFreqConsumerID == nil {
                spectrumService.start()
                lowFreqConsumerID = spectrumService.addConsumer { [weak self] wave in
                    self?.publishLowFrequencyVolume(from: wave)
                }
            }
            spectrumService.updatePlaybackState(isPlaying: isPlaying)
        }

        private func stopSampling() {
            if let id = lowFreqConsumerID {
                spectrumService.removeConsumer(id)
                lowFreqConsumerID = nil
                spectrumService.stop()
            }
        }

        private func publishLowFrequencyVolume(from wave: [Float]) {
            guard lowFreqConsumerID != nil else { return }
            let sub = wave.indices.contains(0) ? wave[0] : 0
            let bass = wave.indices.contains(1) ? wave[1] : sub
            let raw = max(0, min(1, sub * 0.72 + bass * 0.28))
            let shaped = min(0.55, pow(raw, 0.82) * 0.65)
            callFunction(
                "window.AMLLBackground?.setLowFreqVolume",
                arguments: [Double(shaped)],
                label: "setLowFreqVolume"
            )
        }

        private func callFunction(_ functionName: String, arguments: [Any], label: String) {
            guard let data = try? JSONSerialization.data(withJSONObject: arguments),
                  let json = String(data: data, encoding: .utf8)
            else { return }
            call("\(functionName)(...\(json))", label: label)
        }

        private func call(_ script: String, label: String) {
            guard let webView else { return }
            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    Log.debug("AMLL background JS \(label) failed: \(error.localizedDescription)", category: .webview)
                }
            }
        }

        private func collectDiagnostics(label: String) {
            call("window.AMLLBackground?.diagnostics?.('\(label)')", label: "diagnostics.\(label)")
        }

        private func logBackgroundWebMessage(_ body: Any) {
            let text = String(describing: body)
            if text.contains("error") || text.contains("rejection") || text.contains("bootstrap-failed") {
                Log.error("[AMLLBackground] \(text)", category: .webview)
            } else {
                Log.info("[AMLLBackground] \(text)", category: .webview)
            }
        }

        private func imageMIMEType(for data: Data) -> String {
            if data.starts(with: [0xFF, 0xD8, 0xFF]) {
                return "image/jpeg"
            }
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                return "image/png"
            }
            if data.starts(with: [0x52, 0x49, 0x46, 0x46]) {
                return "image/webp"
            }
            return "image/jpeg"
        }
    }
}
