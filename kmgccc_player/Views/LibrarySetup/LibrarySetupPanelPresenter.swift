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
}

@MainActor
private final class LibrarySetupPanelController: NSObject, NSWindowDelegate {
    private let appSession: AppSessionHost
    private let registry: MusicLibraryRegistry
    private let onChange: @MainActor () async -> Void
    private var panel: NSPanel?
    var onClose: (() -> Void)?

    init(appSession: AppSessionHost, registry: MusicLibraryRegistry, onChange: @escaping @MainActor () async -> Void) {
        self.appSession = appSession
        self.registry = registry
        self.onChange = onChange
    }

    func show() {
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
            }
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

    func bringToFront() { panel?.makeKeyAndOrderFront(nil) }
    func close() { panel?.close() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        appSession.librarySetupFlow.operation != .working
    }

    func windowWillClose(_ notification: Notification) {
        appSession.librarySetupFlow.dismiss()
        panel = nil
        onClose?()
    }
}
