import SwiftUI

struct CrashReportSettingsTipView: View {
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("自动发送崩溃报告")
                        .font(.headline)
                    Text("此功能默认开启。报告会经过脱敏，你可以随时在“设置 › 数据管理”中更改选择。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button("暂时关闭", action: onDismiss)
                    .buttonStyle(.bordered)
                Spacer()
                Button("查看设置", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 330)
        .accessibilityElement(children: .contain)
    }
}
