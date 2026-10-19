import SwiftUI

public enum PopupActionKind {
    case secondary, primary, destructive
}

public struct PopupButtonStyle: ButtonStyle {
    public let kind: PopupActionKind
    private let isCloseButton: Bool

    public init(kind: PopupActionKind = .secondary, isCloseButton: Bool = false) {
        self.kind = kind
        self.isCloseButton = isCloseButton
    }

    public func makeBody(configuration: Configuration) -> some View {
        let resolvedKind: PopupActionKind
        if case .secondary = kind, configuration.role == .destructive {
            resolvedKind = .destructive
        } else {
            resolvedKind = kind
        }
        return PopupButtonAppearance(
            kind: resolvedKind, isCloseButton: isCloseButton, isPressed: configuration.isPressed
        ) {
            configuration.label
        }
    }
}

/// Shared label renderer for host ButtonStyle adapters, with environment read in the view.
public struct PopupButtonAppearance<Label: View>: View {
    private let kind: PopupActionKind
    private let isCloseButton: Bool
    private let isPressed: Bool
    private let label: Label
    @Environment(\.popupStyle) private var style
    @Environment(\.popupPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        kind: PopupActionKind = .secondary, isCloseButton: Bool = false, isPressed: Bool = false,
        @ViewBuilder label: () -> Label
    ) {
        self.kind = kind
        self.isCloseButton = isCloseButton
        self.isPressed = isPressed
        self.label = label()
    }

    public var body: some View {
        buttonSurface(
            label
                .font(
                    .system(
                        size: isCloseButton ? style.closeIconSize : style.buttonFontSize,
                        weight: isCloseButton ? .semibold : .medium)
                )
                .foregroundStyle(foreground)
                .padding(buttonInsets)
                .frame(
                    minWidth: isCloseButton ? style.closeButtonSize : style.buttonMinWidth,
                    minHeight: isCloseButton ? style.closeButtonSize : style.buttonHeight)
                // The interactive glass maps pointer hits through the content
                // shape of the view it wraps. Without a shape here the hit
                // region collapses to the drawn label and the rest of the
                // capsule swallows clicks, so the shape has to sit on the
                // content rather than only outside the effect.
                .contentShape(Capsule())
        )
        .contentShape(Capsule())
        .opacity(!isEnabled ? 0.4 : (isPressed ? 0.86 : 1))
    }

    private var buttonInsets: EdgeInsets {
        EdgeInsets(
            top: 0,
            leading: isCloseButton ? 0 : style.buttonHorizontalPadding,
            bottom: 0,
            trailing: isCloseButton ? 0 : style.buttonHorizontalPadding)
    }

    @ViewBuilder private func buttonSurface<SurfaceLabel: View>(_ label: SurfaceLabel) -> some View {
        if reduceTransparency || style.buttonSurface == .solid {
            label.background(fill, in: Capsule())
        } else {
            let glass: Glass = style.buttonSurface == .clearGlass ? .clear : .regular
            label.glassEffect(glass.tint(glassTint).interactive(isEnabled && !reduceMotion), in: Capsule())
        }
    }

    private var glassTint: Color? {
        switch kind {
        case .secondary: nil
        case .primary: palette.accent
        case .destructive: palette.danger
        }
    }

    private var foreground: Color {
        switch kind {
        case .secondary: palette.primary
        case .primary: palette.accentForeground
        case .destructive:
            reduceTransparency || style.buttonSurface == .solid ? palette.dangerForeground : palette.danger
        }
    }

    private var fill: Color {
        switch kind {
        case .secondary: palette.secondary.opacity(0.12)
        case .primary: palette.accent
        case .destructive: palette.danger
        }
    }
}

/// Adjacent glass actions share one rendering container and their natural width.
public struct PopupActionGroup<Content: View>: View {
    private let content: Content
    @Environment(\.popupStyle) private var style

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        GlassEffectContainer(spacing: style.buttonSpacing) {
            HStack(spacing: style.buttonSpacing) { content }
        }
    }
}

/// Keyboard policy is explicit: destructive actions never acquire Return by default.
public struct PopupAction: View {
    private let title: String
    private let kind: PopupActionKind
    private let shortcut: KeyboardShortcut?
    private let action: () -> Void

    public init(
        _ title: String,
        kind: PopupActionKind = .secondary,
        shortcut: KeyboardShortcut? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.kind = kind
        self.shortcut = shortcut
        self.action = action
    }

    public var body: some View {
        Button(title, role: role, action: action)
            .buttonStyle(PopupButtonStyle(kind: kind))
            .keyboardShortcut(shortcut)
    }

    private var role: ButtonRole? {
        switch kind {
        case .destructive: .destructive
        case .secondary, .primary: nil
        }
    }
}
