import AppKit
import PopupKit
import SwiftUI

typealias AppPopupStyle = PopupStyle
typealias AppPopupScrollRegion<Content: View, Actions: View> = PopupScrollRegion<Content, Actions>
typealias AppPopupActionGroup<Content: View> = PopupActionGroup<Content>

/// The renderer owns only appearance; existing presenters retain state and lifecycle.
struct AppPopupFrame<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let onClose: (() -> Void)?
    let showsFooter: Bool
    let showsCloseButton: Bool?
    let rendersSurface: Bool
    let foregroundBlendMode: BlendMode
    let style: PopupStyle
    let foreground: AppForegroundPalette?
    let accent: Color?
    let primaryColor: Color?
    let secondaryColor: Color?
    private let content: Content
    private let footer: Footer

    init(
        title: String, subtitle: String? = nil, systemImage: String? = nil,
        onClose: (() -> Void)? = nil, showsFooter: Bool = true,
        showsCloseButton: Bool? = nil,
        rendersSurface: Bool = true,
        foregroundBlendMode: BlendMode = .normal,
        style: PopupStyle = PopupStyle(), foreground: AppForegroundPalette? = nil, accent: Color? = nil,
        primaryColor: Color? = nil, secondaryColor: Color? = nil,
        @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.onClose = onClose
        self.showsFooter = showsFooter
        self.showsCloseButton = showsCloseButton
        self.rendersSurface = rendersSurface
        self.foregroundBlendMode = foregroundBlendMode
        self.style = style
        self.foreground = foreground
        self.accent = accent
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        Group {
            if rendersSurface {
                popup
                    .presentationBackground(.clear)
                    .presentationCornerRadius(style.cornerRadius)
            } else {
                popup
            }
        }
        .onExitCommand { onClose?() }
    }

    private var popup: some View {
        PopupFrame(
            title: title, subtitle: subtitle, systemImage: systemImage,
            onClose: onClose, showsFooter: showsFooter, showsCloseButton: showsCloseButton,
            rendersSurface: rendersSurface,
            foregroundBlendMode: foregroundBlendMode
        ) {
            content
        } footer: {
            footer
        }
        .appPopupAppearance(
            style: style, foreground: foreground, accent: accent,
            primaryColor: primaryColor, secondaryColor: secondaryColor
        )
    }
}

struct AppPopupCloseButton: View {
    let action: () -> Void
    var body: some View { PopupCloseButton(action: action) }
}

struct AppPopupHeader: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        PopupHeader(title: title, subtitle: subtitle, systemImage: systemImage, onClose: onClose)
    }
}

private struct AppPopupAppearance: ViewModifier {
    var style: PopupStyle
    var foreground: AppForegroundPalette?
    var accent: Color?
    var primaryColor: Color?
    var secondaryColor: Color?
    @EnvironmentObject private var themeStore: ThemeStore

    func body(content: Content) -> some View {
        let colors = foreground ?? themeStore.appForegroundPalette
        content
            .popupAppearance(
                style: style,
                palette: PopupPalette(
                    primary: primaryColor ?? colors.primaryColor, secondary: secondaryColor ?? colors.secondaryColor,
                    accent: accent ?? themeStore.accentColor,
                    surface: themeStore.semanticPalette.ambientSurfaceColor
                )
            )
            .foregroundStyle(primaryColor ?? colors.primaryColor)
            .overlay(alignment: .topLeading) {
                AppDialogWindowDragRegion()
                    .frame(maxWidth: .infinity)
                    .frame(height: style.padding)
                    .padding(.trailing, style.closeMarginTrailing + style.closeButtonSize)
                    .allowsWindowActivationEvents(true)
                    .accessibilityHidden(true)
            }
    }
}

/// Content groups use color hierarchy beneath the one outer glass surface.
private struct AppPopupContentBackground: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?
    @Environment(\.popupPalette) private var palette

    func body(content: Content) -> some View {
        content.background(
            (tint ?? palette.secondary).opacity(tint == nil ? 0.06 : 0.10),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func appPopupContentBackground(cornerRadius: CGFloat = 10, tint: Color? = nil) -> some View {
        modifier(AppPopupContentBackground(cornerRadius: cornerRadius, tint: tint))
    }

    func appPopupAppearance(
        style: PopupStyle = PopupStyle(),
        foreground: AppForegroundPalette? = nil, accent: Color? = nil,
        primaryColor: Color? = nil, secondaryColor: Color? = nil
    ) -> some View {
        modifier(
            AppPopupAppearance(
                style: style, foreground: foreground, accent: accent,
                primaryColor: primaryColor, secondaryColor: secondaryColor))
    }

    /// Use for an existing large workspace whose fields and dimensions stay intact.
    func appPopupSurface() -> some View {
        PopupSurface { self }
            .appPopupAppearance()
            .presentationBackground(.clear)
            .presentationCornerRadius(PopupStyle().cornerRadius)
    }
}

extension PopupStyle {
    /// Anchored hints retain the same renderer with a compact content hierarchy.
    static var appTip: Self {
        var style = Self()
        style.width = 288
        style.padding = 14
        style.sectionSpacing = 10
        style.titleSize = 14
        style.bodySize = 13
        style.iconSize = 16
        style.headerSpacing = 10
        style.closeButtonSize = 24
        style.closeIconSize = 11
        style.closeMarginTop = 8
        style.closeMarginTrailing = 10
        style.buttonMarginTop = 10
        style.buttonMarginBottom = 10
        style.buttonMarginLeading = 10
        style.buttonMarginTrailing = 10
        return style
    }
}


extension View {
    /// End native text editing on an outside click without consuming the destination's event.
    func dismissTextEditingOnOutsideClick(onDismiss: @escaping () -> Void = {}) -> some View {
        background(EditorTextFocusDismissal(onDismiss: onDismiss))
    }
}

private struct EditorTextFocusDismissal: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> EditorTextFocusDismissalView {
        EditorTextFocusDismissalView()
    }

    func updateNSView(_ view: EditorTextFocusDismissalView, context: Context) {
        view.onDismiss = onDismiss
    }

    static func dismantleNSView(_ view: EditorTextFocusDismissalView, coordinator: ()) {
        view.stopMonitoring()
    }
}

private final class EditorTextFocusDismissalView: NSView {
    var onDismiss: () -> Void = {}
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                  let editor = window.firstResponder as? NSTextView, editor.isEditable,
                  let content = window.contentView else { return event }

            // Both field editors and TextEditor views must keep normal text selection.
            var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
            while let view = hit {
                if let text = view as? NSTextView, text.isEditable { return event }
                if let field = view as? NSTextField, field.isEditable { return event }
                hit = view.superview
            }
            if window.makeFirstResponder(nil) { self.onDismiss() }
            return event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
