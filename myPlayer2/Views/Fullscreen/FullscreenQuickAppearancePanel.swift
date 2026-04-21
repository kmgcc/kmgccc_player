//
//  FullscreenQuickAppearancePanel.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen embedded settings panel.
//

import SwiftUI

struct FullscreenQuickAppearancePanel: View {
    let scale: CGFloat
    let onDismiss: () -> Void

    @State private var dismissRegistrationID: UUID?

    private var presentationStyle: FullscreenSettingsPresentationStyle {
        .fullscreenOverlay(scale: scale)
    }

    static func panelSize(
        for scale: CGFloat
    ) -> CGSize {
        FullscreenSettingsPresentationStyle.fullscreenOverlay(scale: scale).panelSize
    }

    private var panelWidth: CGFloat { presentationStyle.panelSize.width }
    private var panelHeight: CGFloat { presentationStyle.panelSize.height }
    private var cornerRadius: CGFloat { presentationStyle.panelCornerRadius }
    private var contentPadding: CGFloat { presentationStyle.panelContentPadding }
    private var closeButtonSize: CGFloat { presentationStyle.closeButtonSize }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // A very light scrim to improve readability over busy fullscreen artwork.
            // Does not change the glass/material types; it only reduces background contrast.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.13))
                .allowsHitTesting(false)

            FullscreenSettingsContainerView(
                presentationStyle: presentationStyle,
                embedsScrollView: true
            )
            .padding(.horizontal, contentPadding)
            .padding(.top, contentPadding)
            .padding(.bottom, presentationStyle.panelBottomPadding)
            .environment(\.colorScheme, .light)

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
                .strokeBorder(GlassStyleTokens.glassBorderColor, lineWidth: GlassStyleTokens.hairlineWidth)
                .allowsHitTesting(false)
        )
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .allowsHitTesting(false)
        )
        .subtleFloatingShadow()
        .controlSize(presentationStyle.controlSize)
        .environment(\.colorScheme, .light)
        .onAppear(perform: registerDismissHandler)
        .onDisappear(perform: unregisterDismissHandler)
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 12 * scale, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: closeButtonSize, height: closeButtonSize)
                .contentShape(Circle())
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.10))
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
