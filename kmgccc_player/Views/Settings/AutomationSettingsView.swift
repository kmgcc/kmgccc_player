import AppKit
import SwiftUI

/// Settings for the local App-owned automation control planes. The business
/// capabilities remain shared with the App, CLI and MCP; this view only owns
/// the user-facing switches and live listener status.
@MainActor
struct AutomationSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeaderLabel("自动化与智能", systemImage: "sparkles.rectangle.stack")

            SettingsSection("本机自动化") {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsSwitchRow(
                        title: "启用本机自动化",
                        isOn: endpointBinding,
                        detail: "允许本机上的 MCP、CLI、脚本和未来的内置 Agent 通过 App-owned Automation 操作播放器。"
                    )

                    Divider()

                    SettingsSwitchRow(
                        title: "允许 MCP 连接",
                        isOn: mcpBinding,
                        detail: "允许 Claude、Codex 等 MCP Host 连接本机端点并调用已授权能力。"
                    )
                    .disabled(!settings.automationEndpointEnabled)
                    .opacity(settings.automationEndpointEnabled ? 1 : 0.55)

                    SettingsSwitchRow(
                        title: "允许 CLI 与脚本",
                        isOn: cliBinding,
                        detail: "允许命令行和本地脚本使用同一套 App-owned Automation 能力。"
                    )
                    .disabled(!settings.automationEndpointEnabled)
                    .opacity(settings.automationEndpointEnabled ? 1 : 0.55)
                }
            }

            SettingsSection("连接与安全") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: appSession.isAutomationRunning ? "circle.fill" : "circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(
                                appSession.isAutomationRunning
                                    ? themeStore.accentColor
                                    : Color.secondary
                            )
                        Text("服务状态")
                            .settingsRowLabelStyle()
                        Spacer(minLength: 12)
                        Text(appSession.isAutomationRunning ? "运行中" : "未运行")
                            .settingsDescriptionStyle()
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("本机连接地址")
                            .settingsSectionTitleStyle()
                        Text(AutomationIPCServer.defaultSocketURL.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Text("普通查询、播放控制、Playlist 操作和 Source 刷新可以直接执行。真实文件删除、批量移动或重命名、历史清除以及底层存储写入，仍由 App 前台确认和权限 scope 共同保护。")
                        .settingsDescriptionStyle()
                }
            }

            SettingsSection("内置 AI") {
                Text("内置 AI 对话和模型运行时暂未启用。本页的设置用于外部 Agent、MCP、CLI 和脚本；它们会复用同一套 App-owned Automation 能力。")
                    .settingsDescriptionStyle()
            }
        }
    }

    private var endpointBinding: Binding<Bool> {
        Binding(
            get: { settings.automationEndpointEnabled },
            set: { newValue in
                settings.automationEndpointEnabled = newValue
                Task { @MainActor in
                    _ = await appSession.setAutomationEndpointEnabled(newValue)
                }
            }
        )
    }

    private var mcpBinding: Binding<Bool> {
        Binding(
            get: { settings.automationMCPEnabled },
            set: { settings.automationMCPEnabled = $0 }
        )
    }

    private var cliBinding: Binding<Bool> {
        Binding(
            get: { settings.automationCLIEnabled },
            set: { settings.automationCLIEnabled = $0 }
        )
    }
}
