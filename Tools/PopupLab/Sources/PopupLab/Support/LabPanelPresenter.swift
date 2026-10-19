import AppKit
import SwiftUI

/// AppKit is confined to the demo host; PopupKit owns no window lifecycle.
@MainActor
final class LabPanelPresenter: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var model: LabModel?
    private var kind: LabSampleKind = .confirmation

    func present(model: LabModel, kind: LabSampleKind) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        self.model = model
        self.kind = kind

        let panel = LabPanel(
            contentRect: NSRect(x: 0, y: 0, width: model.style.width, height: 360),
            styleMask: [.borderless, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Popup Lab"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.delegate = self
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        let content = LabPanelContent(
            model: model,
            kind: kind,
            onClose: { [weak self] in self?.dismiss() },
            onResize: { [weak panel] size in panel?.setContentSize(size) },
            onAppearance: { [weak panel] appearance in
                switch appearance {
                case .system: panel?.appearance = nil
                case .light: panel?.appearance = NSAppearance(named: .aqua)
                case .dark: panel?.appearance = NSAppearance(named: .darkAqua)
                }
            }
        )
        panel.contentView = NSHostingView(rootView: content)
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard model?.canDismiss(kind) != false else { return }
        panel?.close()
    }

    func closeForLabShutdown() {
        panel?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model?.canDismiss(kind) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        model = nil
    }
}

private final class LabPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct LabPanelContent: View {
    @Bindable var model: LabModel
    let kind: LabSampleKind
    let onClose: () -> Void
    let onResize: (CGSize) -> Void
    let onAppearance: (LabAppearance) -> Void

    var body: some View {
        LabSampleView(model: model, kind: kind, usesKeyboardShortcuts: true, onClose: onClose)
            .frame(width: kind == .options ? min(model.style.width, 360) : model.style.width)
            .fixedSize(horizontal: false, vertical: true)
            .preferredColorScheme(model.appearance.colorScheme)
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onResize)
            .onAppear { onAppearance(model.appearance) }
            .onChange(of: model.appearance) { _, value in onAppearance(value) }
    }
}
