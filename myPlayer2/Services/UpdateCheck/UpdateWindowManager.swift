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
    
    var forceShowForTesting: Bool = true
    
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
            showUpdateWindow()
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
    
    private func showUpdateWindow() {
        guard !isPresented else { return }
        
        self.versionInfo = UpdateChecker.shared.remoteInfo
        self.error = UpdateChecker.shared.error
        
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
            versionInfo: versionInfo,
            error: error,
            onDismiss: { [weak self] in
                self?.dismiss()
            },
            onGoToRelease: { [weak self] in
                self?.openReleasePage()
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
    
    private func openReleasePage() {
        let urlString = versionInfo?.releaseURL ?? "https://github.com/kmgcc/kmgccc_player/releases"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
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
