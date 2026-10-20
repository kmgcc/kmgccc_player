//
//  DataManagementSettingsView.swift
//  myPlayer2
//
//  kmgccc_player - Data Management Settings View
//

import MotionKit
import SwiftUI

/// Data management settings split between music-library controls and app data.
struct DataManagementSettingsView: View {
    @State private var selectedTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("数据", systemImage: "arrow.counterclockwise.circle")
            SettingsTabSelector(
                tabs: ["音乐", "应用数据", "后台任务", "存储空间"],
                selectedTab: $selectedTab,
                fillsWidth: true
            )

            switch selectedTab {
            case 0:
                MusicSettingsView()
            case 1:
                ApplicationDataSettingsView()
            case 2:
                BackgroundTasksSettingsView()
            default:
                StorageSettingsView()
            }
        }
    }
}

private struct ApplicationDataSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(LibraryCacheServices.self) private var cacheServices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy
    @AppStorage("telemetry.anonymousUsageEnabled") private var telemetryEnabled: Bool = true
    @AppStorage(CrashReportPreferences.automaticUploadKey) private var automaticCrashReportUploadEnabled = true

    @State private var showResetDataAlert: Bool = false
    @State private var isMoreSettingsExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Import and enrichment settings
            SettingsSection("歌曲信息与补全") {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsSwitchRow(
                        title: "导入时延后补全歌曲信息",
                        isOn: Binding(
                            get: { settings.deferImportEnrichment },
                            set: { settings.deferImportEnrichment = $0 }
                        ),
                        info: "导入时先完成文件复制，在后台补全歌词和封面。"
                    )

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            LibraryCompletionDialogPresenter.present(
                                libraryVM: libraryVM,
                                cacheServices: cacheServices
                            )
                        } label: {
                            Text("补全所有歌曲信息")
                        }
                        .buttonStyle(.borderedProminent)
                        .clipShape(Capsule())
                        .settingsInfoHint("自动联网补全本地曲库中缺失的歌曲信息、封面和歌词。")
                    }
                }
            }

            // Reset app settings
            SettingsSection("重置设置") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("重置应用设置与状态", role: .destructive) {
                        showResetDataAlert = true
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())
                    .settingsInfoHint("清除 App 设置项，恢复默认值。")
                }
            }

            // More settings
            SettingsSection("更多设置", headerTrailing: {
                Button {
                    let policy = configuredMotionPolicy.resolving(
                        accessibilityReduceMotion: reduceMotion
                    )
                    withAnimation(policy.animation(for: motionTokens[.microInteraction])) {
                        isMoreSettingsExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isMoreSettingsExpanded ? 90 : 0))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isMoreSettingsExpanded ? "收起" : "展开")
                .accessibilityLabel(isMoreSettingsExpanded ? "收起更多设置" : "展开更多设置")
            }) {
                if isMoreSettingsExpanded {
                    musicPreferenceResetControl
                } else {
                    Text("包含播放统计数据重置")
                        .settingsDescriptionStyle()
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
        .alert("重置应用设置与状态？", isPresented: $showResetDataAlert) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                resetAppDataExceptMusicLibrary()
            }
        } message: {
            Text("会清除应用偏好、界面布局、播放状态和自定义资料库位置设置。不会删除音乐资料库文件，也不会清除资料库内的歌曲、播放列表、艺人、专辑、自定义排序或手动编辑内容。")
        }
    }

    private func resetAppDataExceptMusicLibrary() {
        AppVersionGate.shared.resetStoredState()
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let preservedTelemetryState = PreservedAnonymousTelemetryState()
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        preservedTelemetryState.restore()
        UserDefaults.standard.synchronize()
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

    private var musicPreferenceResetControl: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("重置播放统计数据", role: .destructive) {
                MusicPreferenceResetDialogPresenter.present(
                    libraryVM: libraryVM,
                    playerVM: playerVM
                )
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .settingsInfoHint("清除音乐播放记录，包括歌曲聆听计数、播放时长等。")
        }
    }
}

private struct PreservedAnonymousTelemetryState {
    private let installID: String?
    private let installSeenAcknowledged: Bool?
    private let installSeenEventID: String?

    init(defaults: UserDefaults = .standard) {
        installID = defaults.string(forKey: Self.installIDKey)
        installSeenAcknowledged = defaults.object(forKey: Self.installSeenAcknowledgedKey) as? Bool
        installSeenEventID = defaults.string(forKey: Self.installSeenEventIDKey)
    }

    func restore(defaults: UserDefaults = .standard) {
        if let installID {
            defaults.set(installID, forKey: Self.installIDKey)
        }
        if let installSeenAcknowledged {
            defaults.set(installSeenAcknowledged, forKey: Self.installSeenAcknowledgedKey)
        }
        if let installSeenEventID {
            defaults.set(installSeenEventID, forKey: Self.installSeenEventIDKey)
        }
    }

    private static let installIDKey = "telemetry.anonymousInstallID"
    private static let installSeenAcknowledgedKey = "telemetry.installSeenAcknowledged"
    private static let installSeenEventIDKey = "telemetry.installSeenEventID"
}
