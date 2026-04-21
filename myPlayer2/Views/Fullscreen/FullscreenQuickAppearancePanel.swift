//
//  FullscreenQuickAppearancePanel.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen embedded settings panel.
//

import SwiftUI

struct FullscreenQuickAppearancePanel: View {
    let glassStyle: FullscreenControlsGlassStyle
    let scale: CGFloat
    let onDismiss: () -> Void

    @State private var dismissRegistrationID: UUID?

    private var presentationStyle: FullscreenSettingsPresentationStyle {
        .fullscreenOverlay(scale: scale, glassMaterialStyle: glassStyle.materialStyle)
    }

    static func panelSize(
        for scale: CGFloat,
        glassMaterialStyle: LiquidGlassPillMaterialStyle
    ) -> CGSize {
        FullscreenSettingsPresentationStyle.fullscreenOverlay(
            scale: scale,
            glassMaterialStyle: glassMaterialStyle
        ).panelSize
    }

    private var panelWidth: CGFloat { presentationStyle.panelSize.width }
    private var panelHeight: CGFloat { presentationStyle.panelSize.height }
    private var cornerRadius: CGFloat { presentationStyle.panelCornerRadius }
    private var contentPadding: CGFloat { presentationStyle.panelContentPadding }
    private var closeButtonSize: CGFloat { presentationStyle.closeButtonSize }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            FullscreenSettingsContainerView(
                presentationStyle: presentationStyle,
                embedsScrollView: true
            )
            .padding(.horizontal, contentPadding)
            .padding(.top, contentPadding)
            .padding(.bottom, presentationStyle.panelBottomPadding)
            .environment(\.colorScheme, .dark)

            closeButton
                .padding(.top, presentationStyle.panelBottomPadding)
                .padding(.trailing, presentationStyle.panelBottomPadding)
        }
        .frame(width: panelWidth, height: panelHeight, alignment: .topLeading)
        .background(panelBackdrop)
        .liquidGlassRect(
            cornerRadius: cornerRadius,
            colorScheme: glassStyle.colorScheme,
            accentColor: glassStyle.accentColor,
            prominence: .prominent,
            materialStyle: glassStyle.materialStyle,
            isFloating: true
        )
        .controlSize(presentationStyle.controlSize)
        .environment(\.colorScheme, .dark)
        .onAppear(perform: registerDismissHandler)
        .onDisappear(perform: unregisterDismissHandler)
    }

    private var panelBackdrop: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(glassBackdropMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.035))
            )
    }

    private var glassBackdropMaterial: AnyShapeStyle {
        switch glassStyle.materialStyle {
        case .clear:
            return AnyShapeStyle(.thickMaterial)
        case .darkGlass:
            return AnyShapeStyle(.regularMaterial)
        }
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
                        .fill(Color.white.opacity(0.06))
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
