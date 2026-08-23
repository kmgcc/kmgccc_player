//
//  AppDialogComponents.swift
//  myPlayer2
//
//  Shared style tokens, panel factory, and view components for app-native
//  dialog panels (NSPanel + popover material). All import-related dialogs,
//  wizards, and confirmation dialogs should use these definitions.
//

import AppKit
import SwiftUI

// MARK: - Style Tokens

enum AppDialogTokens {

    // MARK: Card chrome
    /// Corner radius for the floating glass card. Deliberately compact so the
    /// dialog reads as a small utility surface (matches settings section
    /// cards rather than large-format artwork cards).
    static let windowCornerRadius: CGFloat = 18

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
    static let footerVerticalPadding: CGFloat = 12
    /// Bottom padding so footer buttons clear the rounded bottom corners.
    static let footerBottomPadding: CGFloat = 24

    static let contentHorizontalPadding: CGFloat = 16
    static let contentRowVerticalPadding: CGFloat = 4

    // MARK: Header type
    static let headerTitleFontSize: CGFloat = 18
    static let headerSubtitleFontSize: CGFloat = 12

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

    // MARK: Capsule slider (multi-select-one)
    static let sliderTrackPadding: CGFloat = 3
    static let sliderLabelHorizontalPadding: CGFloat = 10
    static let sliderLabelVerticalPadding: CGFloat = 4
    static let sliderFontSize: CGFloat = 11

    // MARK: Drag import overlay
    static let dropImportCardWidth: CGFloat = 268
    static let dropImportCardHeight: CGFloat = 184
    static let dropImportIconSize: CGFloat = 58
    static let dropImportSpacing: CGFloat = 14
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
        // Dialogs must stay on the desktop when the user clicks into
        // another app; disappearing on deactivation reads as a bug.
        panel.hidesOnDeactivate = false

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

// MARK: - Dialog Window Frame
// The unified chrome skeleton for every app dialog:
// header / divider / content / divider / footer.

struct AppDialogFrame<Header: View, Content: View, Footer: View>: View {
    private let header: Header
    private let content: Content
    private let footer: Footer

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            AppDialogDivider()
            content
            AppDialogDivider()
            footer
        }
    }
}

// MARK: - Dialog Header
// Unified leading header: glass icon capsule + title + subtitle (+ optional
// trailing accessory such as a close button or live counter).

struct AppDialogHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var iconColor: Color
    private let accessory: Accessory

    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        iconColor: Color = .accentColor
    ) where Accessory == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.accessory = EmptyView()
    }

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        iconColor: Color = .accentColor,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 16) {
            if let systemImage {
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(colorScheme == .dark ? 0.18 : 0.12))
                        .frame(
                            width: AppDialogTokens.confirmIconBoxSize,
                            height: AppDialogTokens.confirmIconBoxSize
                        )
                    Image(systemName: systemImage)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                .liquidGlassCircle(
                    colorScheme: colorScheme,
                    accentColor: iconColor,
                    prominence: .prominent,
                    isFloating: true
                )
            }

            VStack(alignment: .leading, spacing: AppDialogTokens.confirmTitleBodySpacing) {
                Text(title)
                    .font(.system(size: AppDialogTokens.headerTitleFontSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: AppDialogTokens.headerSubtitleFontSize))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            accessory
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Dialog Footer
// Unified bottom button area: consistent horizontal/vertical padding, subtle
// material fill, and a hairline divider above the buttons.

struct AppDialogFooter<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, AppDialogTokens.footerHorizontalPadding)
            .padding(.top, AppDialogTokens.footerVerticalPadding)
            .padding(.bottom, AppDialogTokens.footerBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
            .overlay(alignment: .top) {
                AppDialogDivider()
            }
    }
}

// MARK: - Progress Dialog Header
// Shared by BatchImportProgressDialog, NCMImportProgressDialog and
// LyricsFetchProgressDialog.

struct AppDialogProgressHeader: View {
    let title: String
    let counterText: String
    let progress: Double
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: AppDialogTokens.headerSpacing) {
            HStack {
                Text(title)
                    .font(.system(size: AppDialogTokens.headerTitleFontSize, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(counterText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, AppDialogTokens.headerHorizontalPadding)
        .padding(.vertical, AppDialogTokens.headerVerticalPadding)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }
}

// MARK: - Confirmation Dialog Header
// Used by destructive / confirmation dialogs (e.g. ResetPreferenceDataDialog).

struct AppDialogConfirmHeader: View {
    let iconName: String
    let iconColor: Color
    let title: String
    var description: String? = nil

    var body: some View {
        HStack(spacing: AppDialogTokens.confirmHeaderSpacing) {
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

            VStack(alignment: .leading, spacing: AppDialogTokens.confirmTitleBodySpacing) {
                Text(title)
                    .font(.system(size: AppDialogTokens.headerTitleFontSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if let description {
                    Text(description)
                        .font(.system(size: AppDialogTokens.headerSubtitleFontSize))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .padding(.horizontal, AppDialogTokens.headerHorizontalPadding)
        .padding(.vertical, AppDialogTokens.confirmHeaderVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }
}

// MARK: - Drag Import Overlay
// Reuses the dialog chrome language for in-window file-drop affordances.

struct AppDialogDropImportOverlay: View {
    let isVisible: Bool

    @StateObject private var themeStore = ThemeStore.shared

    var body: some View {
        ZStack {
            Color.clear

            if isVisible {
                VStack(spacing: AppDialogTokens.dropImportSpacing) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: AppDialogTokens.dropImportIconSize, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(themeStore.accentColor)

                    Text("释放以导入")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .frame(
                    width: AppDialogTokens.dropImportCardWidth,
                    height: AppDialogTokens.dropImportCardHeight
                )
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(
                        cornerRadius: AppDialogTokens.windowCornerRadius,
                        style: .continuous
                    )
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: AppDialogTokens.windowCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(GlassStyleTokens.glassBorderColor, lineWidth: 0.75)
                )
                .shadow(
                    color: GlassStyleTokens.subtleShadowColor,
                    radius: GlassStyleTokens.subtleShadowRadius,
                    x: 0,
                    y: 10
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.16), value: isVisible)
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
//   - `.primary`    : accent-filled, white label, subtle floating shadow.
//   - `.secondary`  : subtle neutral fill, primary label (cancel / close).
//   - `.destructive`: red-filled, white label (irreversible actions).

struct AppDialogGlassButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case destructive
    }

    var kind: Kind = .secondary
    /// Accent tint for the `.primary` kind. Pass `ThemeStore.shared.accentColor`
    /// to match the rest of the app; ignored for `.secondary` / `.destructive`.
    var tint: Color = .accentColor

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isProminent = kind != .secondary

        return configuration.label
            .font(.system(size: 13, weight: isProminent ? .semibold : .medium))
            .foregroundStyle(isProminent ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .glassEffect(.clear, in: Capsule())
            .background(Capsule().fill(fillColor))
            .overlay(
                Capsule()
                    .strokeBorder(GlassStyleTokens.glassBorderColor, lineWidth: 0.5)
            )
            .shadow(
                color: isProminent ? GlassStyleTokens.subtleShadowColor : .clear,
                radius: isProminent ? GlassStyleTokens.subtleShadowRadius : 0,
                x: 0,
                y: isProminent ? 2 : 0
            )
            .opacity(opacity(isPressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }

    private var fillColor: Color {
        switch kind {
        case .primary:
            return tint.opacity(colorScheme == .dark ? 0.96 : 0.88)
        case .destructive:
            return Color.red.opacity(colorScheme == .dark ? 0.92 : 0.88)
        case .secondary:
            return colorScheme == .dark
                ? Color.white.opacity(0.08)
                : Color.black.opacity(0.08)
        }
    }

    private func opacity(isPressed: Bool) -> Double {
        guard isEnabled else { return 0.4 }
        return isPressed ? 0.75 : 1
    }
}

// MARK: - Capsule Slider (multi-select-one)
// The canonical "choose one" control for dialogs, copied verbatim from the
// settings sliding-knob recipe (`SlidingSelector` + capsule track/knob).

struct AppDialogCapsuleSlider<Selection: Hashable>: View {
    let segments: [Selection]
    @Binding var selection: Selection
    let label: (Selection) -> String

    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        SlidingSelector(
            segments: segments,
            selection: $selection,
            animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
            hSpacing: 0,
            background: {
                Color.clear
            },
            knob: {
                Capsule()
                    .fill(themeStore.accentColor.opacity(0.18))
            },
            content: { segment, isSelected in
                Text(label(segment))
                    .font(.system(size: AppDialogTokens.sliderFontSize, weight: isSelected ? .medium : .regular))
                    .padding(.horizontal, AppDialogTokens.sliderLabelHorizontalPadding)
                    .padding(.vertical, AppDialogTokens.sliderLabelVerticalPadding)
                    .foregroundStyle(isSelected ? themeStore.accentColor : Color.secondary)
                    .contentShape(Rectangle())
                    .accessibilityValue(Text(isSelected ? "已选择" : "未选择"))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        )
        .padding(AppDialogTokens.sliderTrackPadding)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.08))
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Option Menu (custom pop-up single select)
// Custom-drawn replacement for SwiftUI menu pickers inside dialogs: a capsule
// button that opens a small custom list (rounded rows, scrollable for long
// option sets). Used by reconnect flows where labels are too long for a
// capsule slider.

struct AppDialogOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String

    var id: Value { value }
}

struct AppDialogOptionMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [AppDialogOption<Value>]

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isOpen = false
    @State private var hoveredValue: Value?

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? "未选择"
    }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(currentLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Capsule())
            .background(
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(options) { option in
                        optionRow(option)
                    }
                }
                .padding(6)
            }
            .frame(minWidth: 240, maxWidth: 360, maxHeight: 280)
        }
    }

    private func optionRow(_ option: AppDialogOption<Value>) -> some View {
        let isSelected = option.value == selection
        let isHovered = hoveredValue == option.value

        return Button {
            selection = option.value
            isOpen = false
        } label: {
            HStack(spacing: 8) {
                Text(option.label)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(themeStore.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? themeStore.accentColor.opacity(0.12)
                            : (isHovered
                                ? (colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))
                                : Color.clear)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredValue = hovering ? option.value : nil
        }
    }
}

// MARK: - Dialog Option Titles

extension MusicLibraryMode {
    /// Short user-facing title used by the dialog capsule slider.
    var dialogDisplayTitle: String {
        switch self {
        case .managed: return "复制到资料库"
        case .referenced: return "保留原位置"
        }
    }
}

extension ReferencedTrackDeletePolicy {
    /// Short user-facing title used by the dialog capsule slider.
    var dialogDisplayTitle: String {
        switch self {
        case .onlyLibrary: return "仅从资料库移除"
        case .recycleSource: return "将原文件移到废纸篓"
        }
    }
}