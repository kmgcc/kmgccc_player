//
//  ScrollWheelVolumeTipView.swift
//  myPlayer2
//
//  kmgccc_player - Feature Tip for scroll-wheel volume control in fullscreen.
//  The glass treatment intentionally mirrors the fullscreen volume HUD capsule.
//

import PopupKit
import SwiftUI

struct ScrollWheelVolumeTipView: View {
    let onClose: () -> Void
    var scale: CGFloat = 1
    var glassStyle: FullscreenControlsGlassStyle = FullscreenControlsGlassStyle(
        colorScheme: .dark,
        accentColor: nil,
        materialStyle: .normal
    )
    var foregroundColor: Color = .white
    var blendMode: BlendMode = .normal

    var body: some View {
        AppPopupFrame(
            title: "滚轮调节音量", systemImage: "scroll", onClose: onClose, showsFooter: false,
            foregroundBlendMode: blendMode,
            style: AppPopupStyle.appTip.scaled(by: Double(scale)),
            primaryColor: foregroundColor, secondaryColor: foregroundColor.opacity(0.72)
        ) {
            Text("在封面区域滚动滚轮或双指轻扫触控板，即可调节音量")
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            EmptyView()
        }
        .frame(width: 320 * scale)
        .environment(\.colorScheme, glassStyle.colorScheme)
        .zIndex(20)
    }
}
