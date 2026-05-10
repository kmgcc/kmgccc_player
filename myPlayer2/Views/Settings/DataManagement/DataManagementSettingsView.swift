//
//  DataManagementSettingsView.swift
//  myPlayer2
//
//  kmgccc_player - Data Management Settings View
//

import SwiftUI

/// Data management settings: import behavior and cache management.
struct DataManagementSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator

    @State private var showResetDataAlert: Bool = false
    @State private var showClearIndexCacheAlert: Bool = false
    @State private var showClearArtworkColorCacheAlert: Bool = false
    @State private var showClearExternalCacheAlert: Bool = false
    @State private var isClearingExternalCaches: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("数据", systemImage: "arrow.counterclockwise.circle")

            // Library location
            LibraryLocationSettingsSection()

            // Import settings
            SettingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsSwitchRow(
                        title: "导入时延后补全歌词与封面",
                        isOn: Binding(
                            get: { settings.deferImportEnrichment },
                            set: { settings.deferImportEnrichment = $0 }
                        ),
                        detail: "开启后导入会先完成文件复制，再在后台补全歌词和封面，以提高导入速度"
                    )
                }
            }

            // Cache management (all cache-related actions grouped)
            SettingsSection {
                VStack(alignment: .leading, spacing: 16) {
                    // Index cache
                    VStack(alignment: .leading, spacing: 8) {
                        Button("清除索引缓存") {
                            showClearIndexCacheAlert = true
                        }
                            .buttonStyle(.bordered)
                            .clipShape(Capsule())

                        Text("重新建立音乐资料库的索引，供 app 内显示使用，不会影响资料库歌曲文件")
                            .settingsDescriptionStyle()
                    }

                    // Artwork color cache
                    VStack(alignment: .leading, spacing: 8) {
                        Button("清除取色缓存") {
                            showClearArtworkColorCacheAlert = true
                        }
                            .buttonStyle(.bordered)
                            .clipShape(Capsule())

                        Text("若遇到取色异常、颜色显示不正确，可尝试清除取色缓存")
                            .settingsDescriptionStyle()
                    }

                    // External playback cache
                    VStack(alignment: .leading, spacing: 8) {
                        Button(role: .destructive) {
                            showClearExternalCacheAlert = true
                        } label: {
                            if isClearingExternalCaches {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("清理外部播放元数据缓存")
                            }
                        }
                        .buttonStyle(.bordered)
                        .clipShape(Capsule())
                        .disabled(isClearingExternalCaches)

                        Text("遇到问题时，可以尝试清除来自外部播放过程中产生的歌曲元数据匹配结果缓存、手动覆盖元数据。此操作不影响本地播放歌曲的数据")
                            .settingsDescriptionStyle()
                    }

                    // Manual library completion
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            LibraryCompletionDialogPresenter.present(libraryVM: libraryVM)
                        } label: {
                            Text("手动补全所有歌曲信息")
                        }
                        .buttonStyle(.bordered)
                        .clipShape(Capsule())

                        Text("扫描整个本地曲库，按字段只补全缺失的元数据、封面和歌词，不覆盖已有内容")
                            .settingsDescriptionStyle()
                    }
                }
            }

            // Reset app settings
            SettingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    Button("初始化应用设置", role: .destructive) {
                        showResetDataAlert = true
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())

                    Text("将应用设置恢复为初始默认值")
                        .settingsDescriptionStyle()
                }
            }

            // Music preference reset
            SettingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    Button("重置音乐播放数据", role: .destructive) {
                        MusicPreferenceResetDialogPresenter.present(
                            libraryVM: libraryVM,
                            playerVM: playerVM
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())

                    Text("清除播放统计数据，包括歌曲聆听计数、播放时长等")
                        .settingsDescriptionStyle()
                }
            }
        }
        .alert("初始化应用数据？", isPresented: $showResetDataAlert) {
            Button("取消", role: .cancel) {}
            Button("初始化", role: .destructive) {
                resetAppDataExceptMusicLibrary()
            }
        } message: {
            Text("会重置应用设置与界面状态，不会修改音乐资料库内容")
        }
        .alert("清除索引缓存？", isPresented: $showClearIndexCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                Task {
                    await libraryVM.clearIndexCacheAndRebuild()
                }
            }
        } message: {
            Text("将清空索引缓存并立即重新扫描音乐资料库，不会删除歌曲文件或播放列表。")
        }
        .alert("清除取色缓存？", isPresented: $showClearArtworkColorCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                Task {
                    await ArtworkAssetStore.shared.clearCache()
                }
            }
        } message: {
            Text("将清空歌曲封面取色缓存，下次播放时会重新提取颜色，可能降低加载速度")
        }
        .alert("清理外部播放缓存？", isPresented: $showClearExternalCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                clearExternalPlaybackCaches()
            }
        } message: {
            Text("将清除外部播放的手动匹配覆盖、匹配结果、联网封面、联网歌词和相关解析缓存。不会删除本地资料库歌曲。")
        }
    }

    private func resetAppDataExceptMusicLibrary() {
        AppVersionGate.shared.resetStoredState()
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        UserDefaults.standard.synchronize()
    }

    private func clearExternalPlaybackCaches() {
        clearExternalPlaybackCachesAction(
            isClearing: $isClearingExternalCaches,
            playbackCoordinator: playbackCoordinator
        )
    }
}
