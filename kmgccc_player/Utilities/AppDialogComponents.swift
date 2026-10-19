//
//  AppDialogComponents.swift
//  myPlayer2
//
//  Shared style tokens, panel factory, and view components for app-native
//  dialog panels (NSPanel + PopupKit). All import-related dialogs,
//  wizards, and confirmation dialogs should use these definitions.
//

import AppKit
import MotionKit
import PopupKit
import SwiftUI

// MARK: - Style Tokens

enum AppDialogTokens {

    // MARK: Card chrome
    /// Corner radius for the floating glass card. Deliberately compact so the
    /// dialog reads as a small utility surface (matches settings section
    /// cards rather than large-format artwork cards).
    static let windowCornerRadius: CGFloat = PopupStyle().cornerRadius

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
    static let headerHorizontalPadding: CGFloat = PopupStyle().padding
    static let headerVerticalPadding: CGFloat = PopupStyle().padding
    static let headerSpacing: CGFloat = 8

    static let footerHorizontalPadding: CGFloat = PopupStyle().buttonMarginTrailing
    static let footerVerticalPadding: CGFloat = PopupStyle().buttonMarginTop
    /// Bottom padding so footer buttons clear the rounded bottom corners.
    static let footerBottomPadding: CGFloat = PopupStyle().buttonMarginBottom

    static let contentHorizontalPadding: CGFloat = PopupStyle().padding
    static let contentRowVerticalPadding: CGFloat = 4

    // MARK: Header type
    static let headerTitleFontSize: CGFloat = 18
    static let headerSubtitleFontSize: CGFloat = PopupStyle().bodySize

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
    /// Creates a transparent floating host. PopupKit supplies the sole material layer.
    /// The caller adds its hosting view to effectView (the retained compatibility label).
    @MainActor
    static func makePanel(width: CGFloat, height: CGFloat, closable: Bool = true) -> (
        panel: NSPanel, effectView: NSView
    ) {
        let size = NSSize(width: width, height: height)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: closable ? [.titled, .closable, .fullSizeContentView] : [.titled, .fullSizeContentView],
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

        let ve = NSView(frame: NSRect(origin: .zero, size: size))
        ve.autoresizingMask = [.width, .height]
        panel.hasShadow = false
        panel.contentView = ve

        return (panel, ve)
    }

    @MainActor
    static func presentWithMotion(_ panel: NSPanel) {
        panel.center()
        panel.alphaValue = 1
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.opacity = 0
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        animatePanelOpacity(panel, to: 1)
    }

    @MainActor
    static func animatePanelOpacity(
        _ panel: NSPanel,
        to opacity: Float,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        panel.alphaValue = 1
        panel.contentView?.wantsLayer = true
        guard let layer = panel.contentView?.layer else {
            panel.alphaValue = CGFloat(opacity)
            completion()
            return
        }

        let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
        let policy = MotionPolicy.system(
            accessibilityReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        let delay = MotionLayerAnimator.animate(
            layer: layer,
            keyPath: "opacity",
            fromValue: fromOpacity,
            toValue: opacity,
            spec: MotionTokens.standard[.contentReplacement],
            policy: policy,
            animationKey: "motionKit.panel.opacity"
        )

        guard delay > 0 else {
            completion()
            return
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            completion()
        }
    }
}

// MARK: - Dialog Window Frame
// The unified chrome skeleton for every app dialog:
// header / content / footer, rendered on one shared surface.

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
        PopupSurface {
            VStack(spacing: 0) {
                header
                content
                footer
            }
        }
        .appPopupAppearance()
        .presentationBackground(.clear)
        .presentationCornerRadius(PopupStyle().cornerRadius)
    }
}

// MARK: - Dialog Header
// Unified leading header: first-line aligned icon + title + subtitle (+ optional
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
        PopupHeader(title: title, subtitle: subtitle, systemImage: systemImage) { accessory }
            .appPopupAppearance(accent: iconColor)
    }
}

// MARK: - Dialog Footer
// Intrinsic glass actions with margins relative to the popup edges.

struct AppDialogFooter<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        PopupActionGroup { content }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(
                EdgeInsets(
                    top: PopupStyle().buttonMarginTop,
                    leading: PopupStyle().buttonMarginLeading,
                    bottom: PopupStyle().buttonMarginBottom,
                    trailing: PopupStyle().buttonMarginTrailing))
    }
}

// MARK: - Progress Dialog Header
// Shared by BatchImportProgressDialog.

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
        PopupHeader(title: title, subtitle: description, systemImage: iconName)
            .appPopupAppearance(accent: iconColor)
    }
}

// MARK: - Drag Import Overlay
// Reuses the dialog chrome language for in-window file-drop affordances.

struct AppDialogDropImportOverlay: View {
    let isVisible: Bool

    @ObservedObject private var themeStore = ThemeStore.shared

    var body: some View {
        ZStack {
            Color.clear

            if isVisible {
                PopupSurface {
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
                }
                .appPopupAppearance()
                .environmentObject(themeStore)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .motionAnimation(.contentReplacement, value: isVisible)
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
// Window footer actions only. Content tools use AppPanelButtonStyle below.
//   - `.primary`    : accent glass, contrasting label.
//   - `.secondary`  : subtle neutral fill, primary label (cancel / close).
//   - `.destructive`: red-filled, white label (irreversible actions).

struct AppDialogGlassButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case destructive
    }

    var kind: Kind = .secondary
    /// Optional override; by default inherit the popup's ThemeStore palette.
    var tint: Color? = nil

    @Environment(\.popupStyle) private var popupStyle
    @Environment(\.popupPalette) private var popupPalette

    func makeBody(configuration: Configuration) -> some View {
        var palette = popupPalette
        if let tint { palette.accent = tint }
        return PopupButtonAppearance(kind: popupKind(for: configuration.role), isPressed: configuration.isPressed) {
            configuration.label
        }
        .popupAppearance(style: popupStyle, palette: palette)
    }

    private func popupKind(for role: ButtonRole?) -> PopupActionKind {
        if case .secondary = kind, role == .destructive { return .destructive }
        switch kind {
        case .primary: return .primary
        case .secondary: return .secondary
        case .destructive: return .destructive
        }
    }
}

// MARK: - Panel Content Button Style
// Content tools keep their local font and compact sizing, independent of PopupStyle.
struct AppPanelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(minHeight: 24)
            // Same reason as PopupButtonAppearance: the interactive glass reads
            // the content shape, so the capsule belongs on the content itself.
            .contentShape(Capsule())

        return surface(label)
            .contentShape(Capsule())
            .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.8 : 1))
    }

    @ViewBuilder private func surface<SurfaceLabel: View>(_ label: SurfaceLabel) -> some View {
        if reduceTransparency {
            label.background(Color.secondary.opacity(0.12), in: Capsule())
        } else {
            label.glassEffect(.clear.interactive(isEnabled && !reduceMotion), in: Capsule())
        }
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
        }
        .buttonStyle(AppPanelButtonStyle())
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            AppPopupScrollRegion {
                LazyVStack(spacing: PopupStyle().rowSpacing) {
                    ForEach(options) { option in
                        optionRow(option)
                    }
                }
                .padding(PopupStyle().rowPadding)
            }
            .frame(minWidth: 240, maxWidth: 360, maxHeight: 280)
            .appPopupAppearance()
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
                    .font(.system(size: PopupStyle().bodySize))
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
            .padding(PopupStyle().rowPadding)
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
