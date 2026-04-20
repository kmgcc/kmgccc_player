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

    @State private var showClearCacheAlert = false
    @State private var isClearingCaches = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("外部播放", systemImage: "music.note.tv")

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("清理外部 Apple Music 播放的歌曲元数据缓存。")
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
                            Text("清理 Apple Music 元数据缓存")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())
                    .disabled(isClearingCaches)
                }
                .padding(12)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("预留结构", systemImage: "list.bullet.rectangle")
                        .font(.headline)

                    Text("后续可在这里扩展缓存统计、覆盖条目管理、调试信息开关和其它外部播放来源。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
        .alert("清理外部播放缓存？", isPresented: $showClearCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                clearExternalPlaybackCaches()
            }
        } message: {
            Text("将清除 Apple Music 外部播放的手动匹配覆盖、匹配结果、联网封面、联网歌词和相关解析缓存。不会删除本地资料库歌曲。")
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
