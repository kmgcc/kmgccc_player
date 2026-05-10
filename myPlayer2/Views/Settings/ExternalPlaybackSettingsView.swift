//
//  ExternalPlaybackSettingsView.swift
//  myPlayer2
//
//  External playback metadata and cache settings.
//

import SwiftUI

@MainActor
func clearExternalPlaybackCachesAction(
    isClearing: Binding<Bool>,
    playbackCoordinator: PlaybackCoordinator
) {
    guard !isClearing.wrappedValue else { return }
    isClearing.wrappedValue = true
    Task {
        await ExternalPlaybackMetadataStore.shared.clearAllCaches()
        playbackCoordinator.clearExternalPlaybackRuntimeCaches()
        isClearing.wrappedValue = false
    }
}

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

            SettingsSection("播放入口") {
                SettingsSwitchRow(title: "从外部播放", isOn: $showPlaybackSourceSwitcher)
            }

            SettingsSection("其他播放模式") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsSwitchRow(title: "启用\"其他\"播放模式", isOn: $enableSystemNowPlaying)

                    Text("\"其他\" 模式通过 macOS MediaRemote 读取系统当前播放的第三方 App 的元数据，可能出现部分控制不可用、不稳定等问题。如果您只使用本地播放或 Apple Music，可以关闭此选项以保持界面简洁")
                        .settingsDescriptionStyle()
                }
            }

            SettingsSection("缓存") {
                VStack(alignment: .leading, spacing: 12) {
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

                    Text("遇到问题时，可以尝试清除来自外部播放过程中产生的歌曲元数据匹配结果缓存、手动覆盖元数据。此操作不影响本地播放歌曲的数据")
                        .settingsDescriptionStyle()
                }
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
        clearExternalPlaybackCachesAction(
            isClearing: $isClearingCaches,
            playbackCoordinator: playbackCoordinator
        )
    }
}
