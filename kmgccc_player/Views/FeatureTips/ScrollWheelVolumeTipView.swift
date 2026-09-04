//
//  ScrollWheelVolumeTipView.swift
//  myPlayer2
//
//  kmgccc_player - Feature Tip for scroll-wheel volume control in fullscreen.
//  The glass treatment intentionally mirrors the fullscreen volume HUD capsule.
//

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
        HStack(spacing: 12 * scale) {
            Image(systemName: "scroll")
                .font(.system(size: 22 * scale, weight: .semibold))
                .frame(width: 32 * scale)

            VStack(alignment: .leading, spacing: 2 * scale) {
                Text("滚轮调节音量")
                    .font(.system(size: 15 * scale, weight: .semibold))
                Text("在封面区域滚动滚轮或双指轻扫触控板，即可调节音量")
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .frame(width: 22 * scale, height: 22 * scale)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .foregroundStyle(foregroundColor)
        .compositingGroup()
        .blendMode(blendMode)
        .padding(.horizontal, 16 * scale)
        .padding(.vertical, 12 * scale)
        .frame(minWidth: 260 * scale)
        .contentShape(Capsule())
        .liquidGlassPill(
            colorScheme: glassStyle.colorScheme,
            accentColor: glassStyle.accentColor,
            prominence: .standard,
            materialStyle: glassStyle.materialStyle,
            isFloating: true
        )
        .environment(\.colorScheme, glassStyle.colorScheme)
        .zIndex(20)
    }
}