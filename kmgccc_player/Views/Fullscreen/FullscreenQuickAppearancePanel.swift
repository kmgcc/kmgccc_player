//
//  FullscreenQuickAppearancePanel.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen embedded settings panel.
//

import PopupKit
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

    var body: some View {
        AppPopupFrame(
            title: "全屏外观", systemImage: "rectangle.expand.vertical",
            onClose: onDismiss, showsFooter: false,
            style: AppPopupStyle().scaled(by: Double(scale)),
            primaryColor: presentationStyle.primaryTextColor,
            secondaryColor: presentationStyle.secondaryTextColor
        ) {
            AppPopupScrollRegion {
                FullscreenSettingsContainerView(
                    presentationStyle: presentationStyle, embedsScrollView: false, showsHeader: false)
            }
        } footer: {
            EmptyView()
        }
        .frame(width: panelWidth, height: panelHeight, alignment: .topLeading)
        .controlSize(presentationStyle.controlSize)
        .environment(\.colorScheme, foregroundProfile.colorScheme)
        .onAppear(perform: registerDismissHandler)
        .onDisappear(perform: unregisterDismissHandler)
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
