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

    @State private var showResetDataAlert: Bool = false
    @State private var showClearIndexCacheAlert: Bool = false
    @State private var showClearArtworkColorCacheAlert: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("数据", systemImage: "arrow.counterclockwise.circle")

            // Import settings
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(
                        "导入时延后补全歌词与封面",
                        isOn: Binding(
                            get: { settings.deferImportEnrichment },
                            set: { settings.deferImportEnrichment = $0 }
                        )
                    )
                    .toggleStyle(.switch)

                    Text("开启后导入会先完成文件复制与基础信息入库，歌曲会先出现在资料库与播放列表中，再在后台补全歌词和封面。关闭后保持当前导入流程。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }

            // Reset app settings
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("将应用配置恢复为初始默认值，不会修改音乐资料库。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("初始化应用设置", role: .destructive) {
                        showResetDataAlert = true
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())
                }
                .padding(12)
            }

            // Index cache
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("清除本地索引缓存，下次进入资料库时将重新建立索引，不会删除歌曲文件。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("清除索引缓存") {
                        showClearIndexCacheAlert = true
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                }
                .padding(12)
            }

            // Music preference reset
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("批量重置整个音乐资料库中的播放统计偏好数据，只会修改所选统计字段与统计相关旧残留。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("重置音乐偏好数据", role: .destructive) {
                        MusicPreferenceResetDialogPresenter.present(
                            libraryVM: libraryVM,
                            playerVM: playerVM
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())
                }
                .padding(12)
            }

            // Artwork color cache
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("清除歌曲封面取色缓存。若遇到取色异常、颜色显示不正确，可尝试清除缓存。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("清除取色缓存") {
                        showClearArtworkColorCacheAlert = true
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                }
                .padding(12)
            }
        }
        .alert("初始化应用数据？", isPresented: $showResetDataAlert) {
            Button("取消", role: .cancel) {}
            Button("初始化", role: .destructive) {
                resetAppDataExceptMusicLibrary()
            }
        } message: {
            Text("会重置应用设置与界面状态，不会修改音乐资料库内容。")
        }
        .alert("清除索引缓存？", isPresented: $showClearIndexCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                Task {
                    await libraryVM.clearIndexCacheAndRebuild()
                }
            }
        } message: {
            Text("将清空索引缓存并立即重新扫描音乐资料库，不会删除音频、meta.json 或播放列表。")
        }
        .alert("清除取色缓存？", isPresented: $showClearArtworkColorCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                Task {
                    await ArtworkAssetStore.shared.clearCache()
                }
            }
        } message: {
            Text("将清空歌曲封面取色缓存，下次播放时会重新提取颜色。")
        }
    }

    private func resetAppDataExceptMusicLibrary() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        UserDefaults.standard.synchronize()
    }
}
