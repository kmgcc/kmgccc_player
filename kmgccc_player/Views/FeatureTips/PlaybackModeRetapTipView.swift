//
//  PlaybackModeRetapTipView.swift
//  myPlayer2
//
//  Shared playback-order Feature Tip UI and its slider anchor preference.
//

import SwiftUI

struct PlaybackModeRetapTipView: View {
    let onClose: () -> Void
    var usesStandaloneBackground = true

    var body: some View {
        AppPopupFrame(
            title: "播放队列", onClose: onClose, showsFooter: false,
            rendersSurface: usesStandaloneBackground, style: .appTip
        ) {
            Text("再次点击已选择的播放顺序按钮，可快速展开播放队列")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            EmptyView()
        }
        .frame(width: 288, alignment: .leading)
        .zIndex(10)
    }
}

enum PlaybackModeRetapTipAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
