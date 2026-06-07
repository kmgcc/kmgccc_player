//
//  MetadataCandidateStripView.swift
//  myPlayer2
//
//  kmgccc_player - Metadata Candidate List/Strip View
//  Horizontal scrollable list for manual metadata candidate selection
//

import SwiftUI

struct MetadataCandidateStripView: View {
    let candidates: [QQMusicArtworkCandidate]
    let selectedSongMid: String?
    let onSelect: (QQMusicArtworkCandidate) -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    private let cardWidth: CGFloat = 180
    private let cardHeight: CGFloat = 68
    private let spacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("选择元数据候选 (QQ音乐)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
                .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(candidates, id: \.songMid) { candidate in
                        candidateCard(for: candidate)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private func candidateCard(for candidate: QQMusicArtworkCandidate) -> some View {
        let isSelected = selectedSongMid == candidate.songMid
        let appFgSecondary = Color(nsColor: themeStore.appForegroundPalette.secondary)
        let appFgTertiary = Color(nsColor: themeStore.appForegroundPalette.tertiary)

        Button {
            onSelect(candidate)
        } label: {
            HStack(spacing: 8) {
                // Cover thumbnail
                if let imageURL = candidate.imageURL, let url = URL(string: imageURL) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.secondary.opacity(0.12)
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "music.note")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Text details
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title ?? "未知歌曲")
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? themeStore.accentColor : .primary)

                    Text(candidate.artist ?? candidate.artistName ?? "未知歌手")
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .foregroundStyle(appFgSecondary)

                    HStack(spacing: 4) {
                        if let album = candidate.album, !album.isEmpty {
                            Text(album)
                                .font(.system(size: 8))
                                .lineLimit(1)
                                .foregroundStyle(appFgTertiary)
                                .frame(maxWidth: 80, alignment: .leading)
                        }
                        
                        if let duration = candidate.duration {
                            Text(formatDuration(Double(duration)))
                                .font(.system(size: 8))
                                .foregroundStyle(appFgTertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(width: cardWidth, height: cardHeight)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(themeStore.accentColor, lineWidth: 2)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
