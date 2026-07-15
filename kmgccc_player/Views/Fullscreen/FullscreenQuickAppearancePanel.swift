//
//  FullscreenQuickAppearancePanel.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen embedded settings panel.
//

import SwiftUI

struct FullscreenQuickAppearancePanel: View {
    let scale: CGFloat
    let foregroundProfile: FullscreenOverlayForegroundProfile
    let onDismiss: () -> Void

    @State private var dismissRegistrationID: UUID?

    private var presentationStyle: FullscreenSettingsPresentationStyle {
        .fullscreenOverlay(scale: scale, foregroundProfile: foregroundProfile)
    }

    static func panelSize(
        for scale: CGFloat
    ) -> CGSize {
        CGSize(width: 560 * scale, height: 690 * scale)
    }

    private var panelWidth: CGFloat { presentationStyle.panelSize.width }
    private var panelHeight: CGFloat { presentationStyle.panelSize.height }
    private var cornerRadius: CGFloat { presentationStyle.panelCornerRadius }
    private var contentPadding: CGFloat { presentationStyle.panelContentPadding }
    private var closeButtonSize: CGFloat { presentationStyle.closeButtonSize }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Clear Glass remains the surface. This is a single polarity-aware
            // tint layer (not another material) that quiets busy artwork.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(presentationStyle.surfaceTintColor.opacity(0.20))
                .allowsHitTesting(false)

            FullscreenSettingsContainerView(
                presentationStyle: presentationStyle,
                embedsScrollView: true
            )
            .padding(.horizontal, contentPadding)
            .padding(.top, contentPadding)
            .padding(.bottom, presentationStyle.panelBottomPadding)
            .environment(\.colorScheme, foregroundProfile.colorScheme)

            closeButton
                .padding(.top, presentationStyle.panelBottomPadding)
                .padding(.trailing, presentationStyle.panelBottomPadding)
        }
        .frame(width: panelWidth, height: panelHeight, alignment: .topLeading)
        .glassEffect(
            .clear,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    GlassStyleTokens.glassBorderColor(for: foregroundProfile.colorScheme),
                    lineWidth: presentationStyle.scaled(GlassStyleTokens.hairlineWidth)
                )
                .allowsHitTesting(false)
        )
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(presentationStyle.surfaceTintColor.opacity(0.08))
                .allowsHitTesting(false)
        )
        .subtleFloatingShadow()
        .controlSize(presentationStyle.controlSize)
        .environment(\.colorScheme, foregroundProfile.colorScheme)
        .onAppear(perform: registerDismissHandler)
        .onDisappear(perform: unregisterDismissHandler)
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 12 * scale, weight: .semibold))
                .foregroundStyle(presentationStyle.primaryTextColor)
                .frame(width: closeButtonSize, height: closeButtonSize)
                .contentShape(Circle())
                .background(
                    Circle()
                        .fill(presentationStyle.primaryTextColor.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .help("关闭")
    }

    private func registerDismissHandler() {
        guard dismissRegistrationID == nil else { return }
        dismissRegistrationID = FullscreenTransientDismissCoordinator.shared.register {
            onDismiss()
            return true
        }
    }

    private func unregisterDismissHandler() {
        guard let dismissRegistrationID else { return }
        FullscreenTransientDismissCoordinator.shared.unregister(dismissRegistrationID)
        self.dismissRegistrationID = nil
    }
}
