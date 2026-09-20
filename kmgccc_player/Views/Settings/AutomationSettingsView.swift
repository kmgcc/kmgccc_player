import AppKit
import SwiftUI

/// Settings for the local automation control planes. The business
/// capabilities remain shared by the App, CLI and MCP; this view only owns
/// the user-facing switches and connection guidance.
@MainActor
struct AutomationSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var appSession: AppSessionHost

    @State private var isDiagnosticsExpanded = false
    @State private var didCopyMCPConfiguration = false
    @State private var didCopyCLICommand = false

    private struct MCPServerConfiguration: Encodable {
        let command: String
        let args: [String]
    }

    private struct MCPConfiguration: Encodable {
        let mcpServers: [String: MCPServerConfiguration]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeaderLabel("自动化与智能", systemImage: "sparkles.rectangle.stack")

            SettingsSection("本机自动化") {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsSwitchRow(
                        title: "启用本机自动化",
                        isOn: automationBinding
                    )

                    Text("让本机上的 MCP、CLI 和脚本访问播放器。")
                        .settingsDescriptionStyle()
                }
            }

            SettingsSection("MCP 接入") {
                VStack(alignment: .leading, spacing: 14) {
                    commandBlock(
                        title: "MCP stdio",
                        command: "player-automation mcp-stdio",
                        buttonTitle: didCopyMCPConfiguration ? "已复制" : "复制 MCP 配置",
                        buttonSystemImage: didCopyMCPConfiguration ? "checkmark" : "doc.on.doc",
                        action: copyMCPConfiguration
                    )

                    Text("配置可直接粘贴到 MCP 客户端的配置文件。")
                        .settingsDescriptionStyle()

                    Divider()

                    commandBlock(
                        title: "命令行",
                        command: "player-automation cli --help",
                        buttonTitle: didCopyCLICommand ? "已复制" : "复制命令",
                        buttonSystemImage: didCopyCLICommand ? "checkmark" : "doc.on.doc",
                        action: copyCLICommand
                    )
                }
            }

            SettingsSection("运行状态") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: appSession.isAutomationRunning ? "circle.fill" : "circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(
                                appSession.isAutomationRunning
                                    ? Color.green
                                    : Color.secondary
                            )
                        Text("自动化服务")
                            .settingsRowLabelStyle()
                        Spacer(minLength: 12)
                        Text(appSession.isAutomationRunning ? "运行中" : "未运行")
                            .settingsDescriptionStyle()
                            .foregroundStyle(
                                appSession.isAutomationRunning
                                    ? Color.green
                                    : Color.secondary
                            )
                    }

                    DisclosureGroup("高级诊断", isExpanded: $isDiagnosticsExpanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("底层 IPC 端点（仅供诊断排查）")
                                .settingsSectionTitleStyle()
                            Text(AutomationIPCServer.defaultSocketURL.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(.top, 8)
                    }
                }
            }

            // SettingsSection("内置 AI") {
            //     Text("内置 AI 尚未启用。")
            //         .settingsDescriptionStyle()
            // }
        }
    }

    private var automationBinding: Binding<Bool> {
        Binding(
            get: {
                settings.automationEndpointEnabled
                    && settings.automationMCPEnabled
                    && settings.automationCLIEnabled
            },
            set: { newValue in
                settings.automationEndpointEnabled = newValue
                settings.automationMCPEnabled = newValue
                settings.automationCLIEnabled = newValue
                Task { @MainActor in
                    _ = await appSession.setAutomationEndpointEnabled(newValue)
                }
            }
        )
    }

    private func commandBlock(
        title: String,
        command: String,
        buttonTitle: String,
        buttonSystemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .settingsSectionTitleStyle()

            HStack(spacing: 10) {
                commandField(command)

                Button(action: action) {
                    Label(buttonTitle, systemImage: buttonSystemImage)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .clipShape(Capsule())
                .controlSize(.small)
            }
        }
    }

    private func commandField(_ command: String) -> some View {
        Text(command)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var bundledAutomationExecutableURL: URL {
        Bundle.main.url(
            forResource: "player-automation",
            withExtension: nil,
            subdirectory: "Tools"
        ) ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Tools/player-automation")
    }

    private var mcpConfigurationJSON: String {
        let configuration = MCPConfiguration(
            mcpServers: [
                "kmgccc_player": MCPServerConfiguration(
                    command: bundledAutomationExecutableURL.path,
                    args: ["mcp-stdio"]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(configuration),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    private func copyMCPConfiguration() {
        let json = mcpConfigurationJSON
        guard !json.isEmpty else { return }
        copyToPasteboard(json)
        didCopyMCPConfiguration = true
    }

    private func copyCLICommand() {
        copyToPasteboard("player-automation cli --help")
        didCopyCLICommand = true
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
