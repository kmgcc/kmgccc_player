//
//  SettingsInfoHint.swift
//  myPlayer2
//
//  A small "more information" mark beside a setting title. Supplementary
//  notes live in its popover instead of a caption that always takes room.
//

import SwiftUI
import PopupKit

/// Opens while the pointer rests on the mark or on the popover itself, so the
/// note can be read without a click. A click toggles it for keyboard and
/// VoiceOver users.
struct SettingsInfoHint: View {
    let message: String

    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors
    @State private var isPresented = false
    @State private var isAnchorHovered = false
    @State private var isPopoverHovered = false
    @State private var hoverTask: Task<Void, Never>?

    static let popoverWidth: CGFloat = 260
    private static let openDelay: Duration = .milliseconds(180)
    private static let dismissDelay: Duration = .milliseconds(250)

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Button {
            hoverTask?.cancel()
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(
                    isAnchorHovered || isPresented
                        ? presentationStyle.settingsSecondaryTextColor(appColors: appColors)
                        : presentationStyle.settingsTertiaryTextColor(appColors: appColors)
                )
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更多信息")
        .accessibilityValue(message)
        .onHover(perform: anchorHoverChanged)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(message)
                .font(.system(size: AppPopupStyle.appTip.bodySize))
                .foregroundStyle(.secondary)
                .lineSpacing(SettingsStyleTokens.descriptionLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: Self.popoverWidth, alignment: .leading)
                .appPopupAppearance(style: .appTip)
                .onHover(perform: popoverHoverChanged)
        }
        .onDisappear {
            hoverTask?.cancel()
            hoverTask = nil
        }
    }

    private func anchorHoverChanged(_ hovering: Bool) {
        isAnchorHovered = hovering
        guard hovering else {
            scheduleDismiss()
            return
        }
        // A short pause keeps the popover from flashing while the pointer
        // only passes across the row.
        schedule(after: Self.openDelay) {
            if isAnchorHovered { isPresented = true }
        }
    }

    private func popoverHoverChanged(_ hovering: Bool) {
        isPopoverHovered = hovering
        if hovering {
            hoverTask?.cancel()
        } else {
            scheduleDismiss()
        }
    }

    private func scheduleDismiss() {
        schedule(after: Self.dismissDelay) {
            if !isAnchorHovered && !isPopoverHovered {
                isPresented = false
            }
        }
    }

    private func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }
}

extension View {
    /// Places an info mark right after a row title; a nil message leaves the
    /// title as it is.
    @ViewBuilder
    func settingsInfoHint(_ message: String?) -> some View {
        if let message {
            HStack(spacing: 4) {
                self
                SettingsInfoHint(message)
            }
        } else {
            self
        }
    }
}
