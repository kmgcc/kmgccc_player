//
//  GeneralSettingsView.swift
//  myPlayer2
//
//  kmgccc_player - General Settings View
//

import SwiftUI

/// General settings: system integration, updates and data sharing.
struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @AppStorage(UpdatePreferences.automaticUpdatesEnabledKey) private var automaticUpdatesEnabled = true
    @AppStorage("telemetry.anonymousUsageEnabled") private var telemetryEnabled: Bool = true
    @AppStorage(CrashReportPreferences.automaticUploadKey) private var automaticCrashReportUploadEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("通用", systemImage: "gearshape")

            SettingsSection("常规") {
                HStack(alignment: .top, spacing: 14) {
                    SettingsSwitchRow(
                        title: "托盘播放进度",
                        isOn: Binding(
                            get: { settings.dockProgressVisible },
                            set: { settings.dockProgressVisible = $0 }
                        )
                    )
                    .frame(maxWidth: .infinity)

                    Divider()
                        .frame(height: 18)
                        .padding(.top, 2)

                    SettingsSwitchRow(
                        title: "自动更新",
                        isOn: $automaticUpdatesEnabled,
                        info: "自动检查并在后台下载更新；退出 App 或点击侧边栏“重启更新”时安装。"
                    )
                    .frame(maxWidth: .infinity)
                }
            }

            SettingsSection("数据共享") {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsSwitchRow(
                        title: "帮助改进 kmgccc_player",
                        isOn: telemetryEnabledBinding,
                        detail: "发送匿名使用统计，如用户数量、播放来源、皮肤使用与性能指标；统计中不含播放记录、本地文件路径等敏感数据。"
                    )
                    SettingsSwitchRow(
                        title: "自动发送崩溃报告",
                        isOn: automaticCrashReportUploadBinding,
                        detail: "App 意外退出后，自动发送经过脱敏的技术报告，帮助定位错误。再次打开时会询问你是否愿意补充当时的操作。"
                    )
                }
            }
        }
        .onChange(of: automaticUpdatesEnabled) { _, enabled in
            UpdateCoordinator.shared.setAutomaticUpdatesEnabled(enabled)
        }
    }

    private var telemetryEnabledBinding: Binding<Bool> {
        Binding(
            get: { telemetryEnabled },
            set: { newValue in
                telemetryEnabled = newValue
                TelemetryService.shared.setTelemetryEnabled(newValue)
            }
        )
    }

    private var automaticCrashReportUploadBinding: Binding<Bool> {
        Binding(
            get: { automaticCrashReportUploadEnabled },
            set: { newValue in
                automaticCrashReportUploadEnabled = newValue
                CrashReportService.shared.automaticUploadPreferenceDidChange(newValue)
                MetricKitDiagnosticService.shared.automaticUploadPreferenceDidChange(newValue)
            }
        )
    }
}
