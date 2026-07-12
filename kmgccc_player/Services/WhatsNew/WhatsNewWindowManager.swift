//
//  WhatsNewWindowManager.swift
//  myPlayer2
//
//  kmgccc_player - WhatsNew Window Manager
//  Manages a separate window for What's New announcements.
//  Completely independent from main window view hierarchy.
//

import AppKit
import Combine
import SwiftUI
import WhatsNewKit

/// Manages an independent window for displaying What's New announcements.
/// This ensures the What's New display does not affect the main window's view hierarchy.
@MainActor
final class WhatsNewWindowManager: NSObject, NSWindowDelegate, ObservableObject {

    static let shared = WhatsNewWindowManager()

    @Published private(set) var isPresented = false

    private var whatsNewWindow: NSPanel?

    private override init() {
        super.init()
    }

    /// Show the What's New window if there's new content to display.
    func showIfNeeded() {
        guard !isPresented else { return }
        guard WhatsNewConfig.shouldShowWhatsNew() else { return }
        
        let whatsNew = WhatsNewConfiguration.current
        show(whatsNew: whatsNew)
    }

    /// Show the What's New window with specific content.
    private func show(whatsNew: WhatsNew) {
        let whatsNewView = WhatsNewView(whatsNew: whatsNew)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor.windowBackgroundColor
        panel.isOpaque = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()

        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        panel.minSize = NSSize(width: 480, height: 560)

        let themedView = whatsNewView
            .environment(AppSettings.shared)
            .environmentObject(ThemeStore.shared)
            .tint(ThemeStore.shared.accentColor)
            .accentColor(ThemeStore.shared.accentColor)

        let hostingView = NSHostingView(rootView: themedView)
        panel.contentView = hostingView

        applyCurrentAppearance(to: panel)

        whatsNewWindow = panel
        isPresented = true

        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
    }

    /// Apply the current app appearance to the window.
    private func applyCurrentAppearance(to window: NSWindow) {
        let settings = AppSettings.shared
        if settings.followSystemAppearance {
            window.appearance = nil  // Follow system
        } else {
            let appearanceName: NSAppearance.Name = settings.manualAppearance == .dark
                ? .darkAqua
                : .aqua
            window.appearance = NSAppearance(named: appearanceName)
        }
    }

    /// Dismiss the What's New window.
    func dismiss() {
        guard let window = whatsNewWindow else { return }
        
        WhatsNewConfig.markAsSeen()

        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.2
                window.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.whatsNewWindow = nil
                    self.isPresented = false
                }
            }
        )
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        WhatsNewConfig.markAsSeen()
        whatsNewWindow = nil
        isPresented = false
    }
}
