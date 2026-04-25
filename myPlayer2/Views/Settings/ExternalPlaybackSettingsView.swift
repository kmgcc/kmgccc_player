//
//  ExternalPlaybackSettingsView.swift
//  myPlayer2
//
//  External playback metadata and cache settings.
//

import SwiftUI

@MainActor
struct ExternalPlaybackSettingsView: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(AppSettings.self) private var settings

    @State private var showClearCacheAlert = false
    @State private var isClearingCaches = false
    @State private var showPlaybackSourceSwitcher: Bool = AppSettings.shared.showPlaybackSourceSwitcher
    @State private var enableSystemNowPlaying: Bool = AppSettings.shared.enableSystemNowPlayingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("外部播放", systemImage: "music.note.tv")

            GroupBox {
                Toggle("从外部播放", isOn: $showPlaybackSourceSwitcher)
                    .toggleStyle(.switch)
                    .font(.headline)
                    .padding(12)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("启用\"其他\"播放模式", isOn: $enableSystemNowPlaying)
                        .toggleStyle(.switch)
                        .font(.headline)

                    Text("开启后，Sidebar 底部会出现 \"本地 / Apple Music / 其他\" 三种播放模式。关闭后仅保留 \"本地\" 和 \"Apple Music\"。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("\"其他\" 模式通过 macOS MediaRemote 读取系统当前播放的第三方 App（如 Spotify、QQ音乐等）的元数据。该模式依赖私有 API，稳定性有限：可能出现元数据缺失、封面无法获取、播放进度控制不可用、暂停/恢复延迟等问题。如果您只使用本地资料库或 Apple Music，建议关闭此选项以保持界面简洁。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("清理外部播放的歌曲元数据缓存。")
                        .font(.headline)

                    Text("会清除手动匹配覆盖、匹配结果缓存、联网封面缓存、联网歌词缓存，以及其它按外部曲目标识绑定的解析结果。当前播放状态会回退到自动重新匹配。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        showClearCacheAlert = true
                    } label: {
                        if isClearingCaches {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("清理外部播放元数据缓存")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())
                    .disabled(isClearingCaches)
                }
                .padding(12)
            }

        }
        .onAppear {
            showPlaybackSourceSwitcher = settings.showPlaybackSourceSwitcher
            enableSystemNowPlaying = settings.enableSystemNowPlayingMode
        }
        .onChange(of: showPlaybackSourceSwitcher) { _, newValue in
            settings.showPlaybackSourceSwitcher = newValue
        }
        .onChange(of: enableSystemNowPlaying) { _, newValue in
            settings.enableSystemNowPlayingMode = newValue
            // If the user disables "其他" while currently using it,
            // fall back to local playback to avoid a dangling state.
            if !newValue, playbackCoordinator.activeSource == .systemNowPlaying {
                playbackCoordinator.setActiveSource(.local)
            }
        }
        .alert("清理外部播放缓存？", isPresented: $showClearCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                clearExternalPlaybackCaches()
            }
        } message: {
            Text("将清除外部播放的手动匹配覆盖、匹配结果、联网封面、联网歌词和相关解析缓存。不会删除本地资料库歌曲。")
        }
    }

    private func clearExternalPlaybackCaches() {
        guard !isClearingCaches else { return }
        isClearingCaches = true
        Task {
            await ExternalPlaybackMetadataStore.shared.clearAllCaches()
            playbackCoordinator.clearExternalPlaybackRuntimeCaches()
            isClearingCaches = false
        }
    }
}
