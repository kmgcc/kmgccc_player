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
        }
        .onChange(of: showPlaybackSourceSwitcher) { _, newValue in
            settings.showPlaybackSourceSwitcher = newValue
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
