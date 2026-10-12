import PopupKit
import SwiftUI

struct CrashReportSettingsTipView: View {
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        AppPopupFrame(
            title: "自动发送崩溃报告", systemImage: "waveform.badge.magnifyingglass",
            onClose: onDismiss, rendersSurface: false, style: .appTip
        ) {
            Text("此功能默认开启。报告会经过脱敏，你可以随时在“设置 › 数据 › 应用数据 › 数据共享”中更改选择。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            AppPopupActionGroup {
                Button("暂时关闭", action: onDismiss).buttonStyle(AppDialogGlassButtonStyle())
                Button("查看设置", action: onOpenSettings)
                    .buttonStyle(AppDialogGlassButtonStyle(kind: .primary))
            }
        }
        .frame(width: 330)
        .accessibilityElement(children: .contain)
    }
}
