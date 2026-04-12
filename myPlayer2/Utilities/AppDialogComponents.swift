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

    // MARK: Panel layout helpers
    static let progressDialogWidth: CGFloat = 580
    static let rowHeight: CGFloat = 52
    static let headerHeight: CGFloat = 80
    static let footerHeight: CGFloat = 60
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
    /// Creates a standard floating NSPanel with a popover-material NSVisualEffectView as
    /// its content view. The caller must add its hosting view to the returned effectView.
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

        let ve = NSVisualEffectView()
        ve.material = .popover
        ve.blendingMode = .behindWindow
        ve.state = .active
        ve.frame = NSRect(origin: .zero, size: size)
        ve.autoresizingMask = [.width, .height]
        panel.contentView = ve

        return (panel, ve)
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
