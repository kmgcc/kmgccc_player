//
//  DataManagementSettingsView.swift
//  myPlayer2
//
//  kmgccc_player - Data Management Settings View
//

import MotionKit
import SwiftUI

/// Storage and maintenance settings: background work, disk usage and resets.
struct DataManagementSettingsView: View {
    @State private var selectedTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("存储与维护", systemImage: "externaldrive")
            SettingsTabSelector(
                tabs: ["后台任务", "存储空间", "重置"],
                selectedTab: $selectedTab,
                fillsWidth: true
            )

            switch selectedTab {
            case 0:
                BackgroundTasksSettingsView()
            case 1:
                StorageSettingsView()
            default:
                ResetSettingsView()
            }
        }
    }
}

/// Library settings: libraries, sources, song information and cleanup.
struct LibrarySettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("资料库", systemImage: "music.note.house")
            MusicSettingsView()
        }
    }
}

/// Import enrichment, automatic motion artwork and the batch completion entry.
struct LibraryEnrichmentSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(LibraryCacheServices.self) private var cacheServices

    var body: some View {
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

                SettingsSwitchRow(
                    title: "获取动态封面",
                    isOn: Binding(
                        get: { settings.motionArtworkFetchEnabled },
                        set: { settings.motionArtworkFetchEnabled = $0 }
                    ),
                    info: "关闭后不再自动下载，已保存的动态封面保留。"
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
                    .buttonStyle(AppPanelButtonStyle())

                    Text("在此处批量联网补全所有本地曲库中缺失的歌曲信息、封面和歌词。")
                        .settingsDescriptionStyle()
                }
            }
        }
    }
}

private struct ResetSettingsView: View {
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy

    @State private var showResetDataAlert: Bool = false
    @State private var isMoreSettingsExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Reset app settings
            SettingsSection("重置设置") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("重置应用设置与状态", role: .destructive) {
                        showResetDataAlert = true
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())

                    Text("清除 App 设置项，恢复默认值。")
                        .settingsDescriptionStyle()
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

            Text("清除音乐播放记录，包括歌曲聆听计数、播放时长等。")
                .settingsDescriptionStyle()
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
