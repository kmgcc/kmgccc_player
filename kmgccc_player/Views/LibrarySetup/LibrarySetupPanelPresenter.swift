import AppKit
import SwiftUI

@MainActor
enum LibrarySetupPanelPresenter {
    private static var controller: LibrarySetupPanelController?
    private static var isPreparing = false

    static func present(appSession: AppSessionHost, onChange: @escaping @MainActor () async -> Void = {}) {
        if let controller {
            controller.bringToFront()
            return
        }
        guard !isPreparing else { return }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            let registry = await appSession.musicLibraryRegistrySnapshot()
            guard appSession.librarySetupFlow.presentation != .none,
                  self.controller == nil else { return }
            let controller = LibrarySetupPanelController(
                appSession: appSession,
                registry: registry,
                onChange: onChange
            )
            self.controller = controller
            controller.onClose = { self.controller = nil }
            controller.show()
        }
    }

    static func close() {
        controller?.close()
    }

    /// Panel used to attach file/folder pickers as sheets, so closing the
    /// picker returns focus to the wizard instead of the main window.
    static var sheetAnchorPanel: NSPanel? { controller?.sheetAnchorPanel }

    /// Re-assert app + panel focus after an app-modal session (file picker)
    /// completes, so the wizard — not the main window — becomes key again.
    static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.bringToFront()
    }
}

@MainActor
private final class LibrarySetupPanelController: NSObject, NSWindowDelegate {
    private let appSession: AppSessionHost
    private let registry: MusicLibraryRegistry
    private let onChange: @MainActor () async -> Void
    private var panel: NSPanel?
    private var didFinishClosing = false
    var onClose: (() -> Void)?

    init(appSession: AppSessionHost, registry: MusicLibraryRegistry, onChange: @escaping @MainActor () async -> Void) {
        self.appSession = appSession
        self.registry = registry
        self.onChange = onChange
    }

    func show() {
        didFinishClosing = false
        let size = NSSize(width: 500, height: 430)
        let result = AppDialogTokens.makePanel(width: size.width, height: size.height)
        let panel = result.panel
        panel.delegate = self
        let root = LibrarySetupFlow(
            flow: appSession.librarySetupFlow,
            registry: registry,
            onChange: { [weak self] in
                await self?.onChange()
                if self?.appSession.librarySetupFlow.presentation == LibrarySetupViewModel.Presentation.none {
                    self?.close()
                }
            },
            onRequestClose: { [weak self] in self?.close() }
        )
        .environmentObject(appSession)
        .environmentObject(ThemeStore.shared)
        .frame(width: size.width, height: size.height)
        .onChange(of: appSession.librarySetupFlow.presentation) { _, presentation in
            if presentation == .none { self.close() }
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = result.effectView.bounds
        hosting.autoresizingMask = [.width, .height]
        result.effectView.addSubview(hosting)
        self.panel = panel
        AppDialogTokens.presentWithFade(panel)
    }

    var sheetAnchorPanel: NSPanel? { panel }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }
    func close() {
        finishClosing()
    }

    private func finishClosing() {
        guard !didFinishClosing else { return }
        didFinishClosing = true
        appSession.librarySetupFlow.dismiss()

        // `NSPanel.close()` can be visually outlived by the hosting view when
        // the SwiftUI presentation changes in the same run-loop turn. Remove
        // the delegate first, explicitly order the panel out, then close it;
        // this makes the imperative window lifecycle independent of view diffing.
        let panel = self.panel
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.close()
        self.panel = nil

        let callback = onClose
        onClose = nil
        callback?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }

    func windowWillClose(_ notification: Notification) {
        finishClosing()
    }
}
