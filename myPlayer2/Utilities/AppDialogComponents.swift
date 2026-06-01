//
//  AppDialogComponents.swift
//  myPlayer2
//
//  Shared style tokens, panel factory, and view components for app-native
//  dialog panels (NSPanel + popover material). All import-related dialogs
//  and confirmation dialogs should use these definitions.
//

import AppKit
import SwiftUI

// MARK: - Style Tokens

enum AppDialogTokens {

    // MARK: Card chrome
    /// Large corner radius for the floating glass card. Matches UpdateWindowManager.
    static let windowCornerRadius: CGFloat = 28

    // MARK: Panel layout helpers
    static let progressDialogWidth: CGFloat = 580
    static let rowHeight: CGFloat = 52
    static let headerHeight: CGFloat = 80
    static let footerHeight: CGFloat = 74
    static let maxVisibleRows: Int = 9
    static let listVerticalPadding: CGFloat = 8

    static func windowHeight(rowCount: Int) -> CGFloat {
        let visible = min(rowCount, maxVisibleRows)
        return headerHeight + CGFloat(visible) * rowHeight + listVerticalPadding + footerHeight
    }

    // MARK: Shared spacing
    static let headerHorizontalPadding: CGFloat = 20
    static let headerVerticalPadding: CGFloat = 16
    static let headerSpacing: CGFloat = 8

    static let footerHorizontalPadding: CGFloat = 20
    static let footerVerticalPadding: CGFloat = 14
    /// Extra bottom padding so footer buttons clear the rounded bottom corners
    /// and the glass capsule edge. Matches the update window's generous bottom inset.
    static let footerBottomPadding: CGFloat = 30

    static let contentHorizontalPadding: CGFloat = 16
    static let contentRowVerticalPadding: CGFloat = 4

    // MARK: Item rows
    static let rowCornerRadius: CGFloat = 8
    static let rowHorizontalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 6

    // MARK: Dividers & fills
    static let dividerOpacity: Double = 0.5
    static let rowFillDark: Double = 0.05    // Color.white.opacity(...)
    static let rowFillLight: Double = 0.03   // Color.black.opacity(...)

    // MARK: Confirmation dialog header
    static let confirmIconBoxSize: CGFloat = 52
    static let confirmIconBoxCornerRadius: CGFloat = 14
    static let confirmIconSize: CGFloat = 24
    static let confirmIconOpacity: Double = 0.12
    static let confirmHeaderVerticalPadding: CGFloat = 24
    static let confirmHeaderSpacing: CGFloat = 12
    static let confirmTitleBodySpacing: CGFloat = 4
}

// MARK: - NSPanel Factory

extension AppDialogTokens {
    /// Creates a standard floating NSPanel styled as a large-radius glass card, matching
    /// the update window (`UpdateWindowManager`): popover material, clear background,
    /// hidden traffic-light buttons, and a rounded, clipped visual-effect content view.
    /// The caller must add its hosting view to the returned effectView.
    @MainActor
    static func makePanel(width: CGFloat, height: CGFloat) -> (panel: NSPanel, effectView: NSVisualEffectView) {
        let size = NSSize(width: width, height: height)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear

        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let ve = NSVisualEffectView()
        ve.material = .popover
        ve.blendingMode = .behindWindow
        ve.state = .active
        ve.frame = NSRect(origin: .zero, size: size)
        ve.autoresizingMask = [.width, .height]
        ve.wantsLayer = true
        ve.layer?.cornerRadius = windowCornerRadius
        ve.layer?.masksToBounds = true
        panel.contentView = ve

        return (panel, ve)
    }

    /// Centers and presents a panel with the same gentle fade-in used by the update window.
    @MainActor
    static func presentWithFade(_ panel: NSPanel) {
        panel.center()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
    }
}

// MARK: - Progress Dialog Header
// Shared by NCMImportProgressDialog and LyricsFetchProgressDialog.

struct AppDialogProgressHeader: View {
    let title: String
    let counterText: String
    let progress: Double

    var body: some View {
        VStack(spacing: AppDialogTokens.headerSpacing) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text(counterText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, AppDialogTokens.headerHorizontalPadding)
        .padding(.vertical, AppDialogTokens.headerVerticalPadding)
        .background(.thinMaterial)
    }
}

// MARK: - Confirmation Dialog Header
// Used by destructive / confirmation dialogs (e.g. ResetPreferenceDataDialog).

struct AppDialogConfirmHeader: View {
    let iconName: String
    let iconColor: Color
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: AppDialogTokens.confirmHeaderSpacing) {
            Image(systemName: iconName)
                .font(.system(size: AppDialogTokens.confirmIconSize, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(
                    width: AppDialogTokens.confirmIconBoxSize,
                    height: AppDialogTokens.confirmIconBoxSize
                )
                .background(
                    RoundedRectangle(
                        cornerRadius: AppDialogTokens.confirmIconBoxCornerRadius,
                        style: .continuous
                    )
                    .fill(iconColor.opacity(AppDialogTokens.confirmIconOpacity))
                )

            VStack(spacing: AppDialogTokens.confirmTitleBodySpacing) {
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, AppDialogTokens.headerHorizontalPadding)
        .padding(.vertical, AppDialogTokens.confirmHeaderVerticalPadding)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }
}

// MARK: - Row Background Modifier
// Apply to any list row view that needs the standard subtle rounded background.

private struct AppDialogRowBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(
                    cornerRadius: AppDialogTokens.rowCornerRadius,
                    style: .continuous
                )
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(AppDialogTokens.rowFillDark)
                        : Color.black.opacity(AppDialogTokens.rowFillLight)
                )
            )
    }
}

extension View {
    func appDialogRowBackground() -> some View {
        modifier(AppDialogRowBackgroundModifier())
    }
}

// MARK: - Styled Divider
// Shared semi-transparent separator used between header/content/footer.

struct AppDialogDivider: View {
    var body: some View {
        Divider()
            .opacity(AppDialogTokens.dividerOpacity)
    }
}

// MARK: - Glass Capsule Button Style
// Shared button style for app dialog footers. Mirrors the update window
// (`UpdateAlertView`) so import, confirmation, and update dialogs share one
// button language.
//   - `.primary`  : accent-filled, white label, subtle floating shadow.
//   - `.secondary`: subtle neutral fill, primary label (cancel / close).

struct AppDialogGlassButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    var kind: Kind = .secondary
    /// Accent tint for the `.primary` kind. Pass `ThemeStore.shared.accentColor`
    /// to match the rest of the app; ignored for `.secondary`.
    var tint: Color = .accentColor

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isPrimary = kind == .primary

        return configuration.label
            .font(.system(size: 13, weight: isPrimary ? .semibold : .medium))
            .foregroundStyle(isPrimary ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .glassEffect(.clear, in: Capsule())
            .background(Capsule().fill(fillColor(isPrimary: isPrimary)))
            .overlay(
                Capsule()
                    .strokeBorder(GlassStyleTokens.glassBorderColor, lineWidth: 0.5)
            )
            .shadow(
                color: isPrimary ? GlassStyleTokens.subtleShadowColor : .clear,
                radius: isPrimary ? GlassStyleTokens.subtleShadowRadius : 0,
                x: 0,
                y: isPrimary ? 2 : 0
            )
            .opacity(opacity(isPressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }

    private func fillColor(isPrimary: Bool) -> Color {
        if isPrimary {
            return tint.opacity(colorScheme == .dark ? 0.96 : 0.88)
        }
        return colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.08)
    }

    private func opacity(isPressed: Bool) -> Double {
        guard isEnabled else { return 0.4 }
        return isPressed ? 0.75 : 1
    }
}
