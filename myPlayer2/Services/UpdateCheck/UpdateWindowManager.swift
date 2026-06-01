//
//  UpdateWindowManager.swift
//  myPlayer2
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class UpdateWindowManager: NSObject, NSWindowDelegate, ObservableObject {
    
    static let shared = UpdateWindowManager()
    
    @Published private(set) var isPresented = false
    
    private var updateWindow: NSPanel?
    private var versionInfo: RemoteVersionInfo?
    private var error: Error?
    private var alertKind: UpdateAlertKind = .updateAvailable
    
    var forceShowForTesting: Bool = false
    
    private override init() {
        super.init()
    }
    
    func checkAndShowIfNeeded() async {
        print("[UpdateWindowManager] Starting update check...")
        
        await UpdateChecker.shared.checkForUpdates()
        
        let localVersion = UpdateChecker.shared.localVersion
        let remoteVersion = UpdateChecker.shared.remoteInfo?.latestVersion ?? "N/A"
        
        print("[UpdateWindowManager] Version check result:")
        print("  - Local version: \(localVersion)")
        print("  - Remote version: \(remoteVersion)")
        
        let shouldShow = UpdateChecker.shared.shouldShowUpdate(forceShow: forceShowForTesting)
        print("  - Should show update: \(shouldShow)")
        
        if shouldShow {
            print("[UpdateWindowManager] Showing update alert (remote > local)")
            showUpdateWindow(kind: .updateAvailable)
        } else {
            if UpdateChecker.shared.error != nil {
                print("[UpdateWindowManager] Not showing update: request or parse failed")
            } else if UpdateChecker.shared.remoteInfo == nil {
                print("[UpdateWindowManager] Not showing update: no remote info available")
            } else {
                print("[UpdateWindowManager] Not showing update: already up to date or remote <= local")
            }
        }
    }

    func checkManuallyAndShowResult() async {
        print("[UpdateWindowManager] Starting manual update check...")

        await UpdateChecker.shared.checkForUpdates()

        if UpdateChecker.shared.error != nil || UpdateChecker.shared.remoteInfo == nil {
            print("[UpdateWindowManager] Manual check failed; showing failure alert")
            showUpdateWindow(kind: .failed)
        } else if UpdateChecker.shared.shouldShowUpdate(forceShow: forceShowForTesting) {
            print("[UpdateWindowManager] Manual check found update")
            showUpdateWindow(kind: .updateAvailable)
        } else {
            print("[UpdateWindowManager] Manual check found app is up to date")
            showUpdateWindow(kind: .upToDate)
        }
    }
    
    private func showUpdateWindow(kind: UpdateAlertKind) {
        guard !isPresented else { return }
        
        self.versionInfo = UpdateChecker.shared.remoteInfo
        self.error = UpdateChecker.shared.error
        self.alertKind = kind
        
        let windowSize = NSSize(width: 440, height: 500)
        
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        
        panel.isOpaque = false
        panel.backgroundColor = .clear
        
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.frame = NSRect(origin: .zero, size: windowSize)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 28
        panel.contentView = visualEffect
        
        let alertView = UpdateAlertView(
            kind: alertKind,
            versionInfo: versionInfo,
            error: error,
            onDismiss: { [weak self] in
                self?.dismiss()
            },
            onDownload: { [weak self] in
                self?.openDownloadURL()
                self?.dismiss()
            },
            onOpenGitHubRelease: { [weak self] in
                self?.openGitHubReleasePage()
                self?.dismiss()
            }
        )
        
        let themedView = alertView
            .environment(AppSettings.shared)
            .environmentObject(ThemeStore.shared)
            .tint(ThemeStore.shared.accentColor)
            .accentColor(ThemeStore.shared.accentColor)
        
        let hostingView = NSHostingView(rootView: themedView)
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]
        
        visualEffect.addSubview(hostingView)
        
        applyCurrentAppearance(to: panel)
        
        updateWindow = panel
        isPresented = true
        
        panel.level = .floating
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
        
        print("[UpdateWindowManager] Update alert window shown")
    }
    
    private func openDownloadURL() {
        let urlString = versionInfo?.downloadURL ?? versionInfo?.releaseURL
        let url = resolveURL(urlString)
            ?? resolveURL(versionInfo?.releaseURL)
            ?? UpdateLinks.githubReleaseURL
        NSWorkspace.shared.open(url)
    }

    private func openGitHubReleasePage() {
        NSWorkspace.shared.open(UpdateLinks.githubReleaseURL)
    }

    private func resolveURL(_ rawValue: String?) -> URL? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme != nil else {
            return nil
        }
        return url
    }
    
    private func applyCurrentAppearance(to window: NSWindow) {
        let settings = AppSettings.shared
        if settings.followSystemAppearance {
            window.appearance = nil
        } else {
            let appearanceName: NSAppearance.Name = settings.manualAppearance == .dark
                ? .darkAqua
                : .aqua
            window.appearance = NSAppearance(named: appearanceName)
        }
    }
    
    func dismiss() {
        guard let window = updateWindow else { return }
        
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.2
                window.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.updateWindow = nil
                    self.isPresented = false
                }
            }
        )
    }
    
    func windowWillClose(_ notification: Notification) {
        updateWindow = nil
        isPresented = false
    }
}
