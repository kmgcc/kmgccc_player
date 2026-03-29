//
//  What'sNewView.swift
//  myPlayer2
//
//  kmgccc_player - What's New modal shown on app launch
//

import SwiftUI

// MARK: - Feature Item Model

struct WhatsNewFeature: Identifiable {
    let id = UUID()
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
}

// MARK: - What's New View

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let features: [WhatsNewFeature] = [
        WhatsNewFeature(
            icon: "music.note.house.fill",
            iconColor: .blue,
            title: "全新播放界面",
            description: "沉浸式磁带播放视图，配合实时频谱可视化，带来更纯粹的聆听体验。"
        ),
        WhatsNewFeature(
            icon: "quote.bubble.fill",
            iconColor: .purple,
            title: "AMLL 歌词集成",
            description: "类 Apple Music 的逐行歌词显示，支持平滑滚动与精准同步。"
        ),
        WhatsNewFeature(
            icon: "sparkles",
            iconColor: .orange,
            title: "Liquid Glass 设计",
            description: "全面适配 macOS 26 Liquid Glass 视觉语言，界面通透、克制、原生。"
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                // App icon placeholder
                Image(systemName: "music.note.list")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                Text("What's New")
                    .font(.system(size: 28, weight: .bold))

                Text("See what changed in this version")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            Divider()
                .padding(.horizontal, 24)

            // Feature list
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                        FeatureRow(feature: feature)

                        if index < features.count - 1 {
                            Divider()
                                .padding(.leading, 68)
                        }
                    }
                }
                .padding(.vertical, 16)
            }

            Divider()
                .padding(.horizontal, 24)

            // Footer button
            HStack {
                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("Continue")
                        .fontWeight(.medium)
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Spacer()
            }
            .padding(.vertical, 20)
        }
        .frame(width: 480, height: 520)
        .background(colorScheme == .dark
            ? Color(nsColor: NSColor.windowBackgroundColor)
            : Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

// MARK: - Feature Row

struct FeatureRow: View {
    let feature: WhatsNewFeature

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Icon
            Image(systemName: feature.icon)
                .font(.system(size: 24))
                .foregroundStyle(feature.iconColor)
                .frame(width: 40, height: 40)
                .background(feature.iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            // Text content
            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.headline)

                Text(feature.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

// MARK: - Preview

#Preview("What's New") {
    WhatsNewView()
}
