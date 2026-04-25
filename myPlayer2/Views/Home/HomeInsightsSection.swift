//
//  HomeInsightsSection.swift
//  myPlayer2
//
//  Listening insights: stats, preference ranking, and calendar heatmap.
//  Phase 1: basic stat cards and ranking table.
//  Phase 3 will add calendar heatmap and glass materials.
//

import AppKit
import SwiftUI

struct HomeInsightsSection: View {
    let homeVM: HomeViewModel

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader
            statsRow

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(NSLocalizedString("home.insights.preference_ranking", comment: "Preference ranking"))
                        .font(.caption)
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    HomePreferenceRankingView(items: homeVM.preferenceRanking)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    Text(NSLocalizedString("home.insights.daily_listening", comment: "Daily listening"))
                        .font(.caption)
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    HomeListeningHeatmapView(dailyMap: homeVM.dailyListeningMap)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 4)
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("home.section.you", comment: "You"))
                    .font(.caption)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(NSLocalizedString("home.section.listening_insights", comment: "Listening Insights"))
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.3)
            }
            Spacer()
        }
    }

    private var statsRow: some View {
        HStack(spacing: 14) {
            HomeStatCard(
                label: NSLocalizedString("home.stat.total_songs", comment: "Total songs"),
                value: "\(homeVM.totalTrackCount)",
                unit: NSLocalizedString("home.stat.tracks", comment: "tracks"),
                subtitle: NSLocalizedString("home.stat.in_library", comment: "in your library")
            )

            HomeStatCard(
                label: NSLocalizedString("home.stat.total_plays", comment: "Total plays"),
                value: formattedNumber(homeVM.totalPlayCount),
                unit: NSLocalizedString("home.stat.plays", comment: "plays"),
                subtitle: NSLocalizedString("home.stat.all_time", comment: "all-time")
            )

            HomeStatCard(
                label: NSLocalizedString("home.stat.listening_time", comment: "Listening time"),
                value: "\(Int(homeVM.totalListeningSeconds / 3600))",
                unit: NSLocalizedString("home.stat.hours", comment: "hours"),
                subtitle: NSLocalizedString("home.stat.this_year", comment: "this year")
            )

            // Favorite artist card
            HomeInsightsCardContainer {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("home.stat.favorite_artist", comment: "Favorite artist"))
                        .font(.caption2)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    if let name = homeVM.favoriteArtistName {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                            Text("\(homeVM.favoriteArtistAlbumCount) \(NSLocalizedString("home.albums", comment: "albums"))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("\u{2014}")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func formattedNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - Stat Card

private struct HomeStatCard: View {
    let label: String
    let value: String
    let unit: String
    let subtitle: String

    var body: some View {
        HomeInsightsCardContainer {
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .font(.caption2)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-0.5)
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Shared Insights Card Container

private struct HomeInsightsCardContainer<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(colorScheme == .dark
                          ? Color.white.opacity(0.04)
                          : Color.white.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.15 : 0.05),
                radius: 6, y: 2
            )
    }
}

// MARK: - Preference Ranking

private struct HomePreferenceRankingView: View {
    let items: [HomeViewModel.PreferenceRankItem]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HomeInsightsCardContainer {
            VStack(spacing: 0) {
                if items.isEmpty {
                    Text(NSLocalizedString("home.insights.no_data", comment: "Not enough listening data yet"))
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    // Header row
                    HStack {
                        Text("#")
                            .frame(width: 28)
                        Text(NSLocalizedString("home.insights.song_artist", comment: "Song \u{00B7} Artist"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(NSLocalizedString("home.insights.preference", comment: "Preference"))
                            .frame(width: 120)
                        Text(NSLocalizedString("home.insights.plays", comment: "Plays"))
                            .frame(width: 50, alignment: .trailing)
                    }
                    .font(.caption2)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        HomeRankRow(rank: index + 1, item: item)
                        if index < items.count - 1 {
                            Divider()
                                .padding(.horizontal, 12)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct HomeRankRow: View {
    let rank: Int
    let item: HomeViewModel.PreferenceRankItem
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    // Normalize score: preferenceScoreCache can range roughly -100..+100
    private var normalizedScore: Double {
        max(0, min(1, (item.score + 100) / 200))
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("\(rank)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(themeStore.accentColor.opacity(0.12))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(themeStore.accentColor.opacity(colorScheme == .dark ? 0.7 : 0.55))
                            .frame(width: proxy.size.width * normalizedScore)
                    }
                }
                .frame(height: 6)
                .frame(width: 70)

                Text(String(format: "%.0f", item.score))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
            .frame(width: 120)

            Text("\(item.playCount)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(themeStore.accentColor.opacity(isHovering ? 0.06 : 0))
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

// MARK: - Listening Heatmap

struct HomeListeningHeatmapView: View {
    let dailyMap: [Date: Int]

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    private let monthLabels = ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"]
    private let rows = 7
    private let cols = 52

    var body: some View {
        HomeInsightsCardContainer {
            VStack(spacing: 10) {
                HStack {
                    Text(NSLocalizedString("home.insights.daily_listening", comment: "Daily listening"))
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text(yearMonthLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                let cells = buildCells()
                let gridRows = Array(repeating: GridItem(.flexible(), spacing: 2), count: rows)

                LazyHGrid(rows: gridRows, spacing: 2) {
                    ForEach(0..<cells.count, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(cellColor(for: cells[i]))
                            .frame(minWidth: 8, minHeight: 8)
                    }
                }
                .frame(minHeight: 80)

                HStack(spacing: 0) {
                    ForEach(0..<12, id: \.self) { i in
                        Text(monthLabels[i])
                            .font(.system(size: 10))
                            .foregroundStyle(i == currentMonth ? .primary : .tertiary)
                            .fontWeight(i == currentMonth ? .semibold : .regular)
                            .frame(maxWidth: .infinity)
                    }
                }

                HStack {
                    Text(NSLocalizedString("home.insights.less", comment: "Less"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    HStack(spacing: 3) {
                        ForEach(0..<5) { level in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(cellColor(for: level))
                                .frame(width: 10, height: 10)
                        }
                    }
                    Spacer()
                    Text(NSLocalizedString("home.insights.more", comment: "More"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(4)
        }
    }

    private var currentMonth: Int {
        Calendar.current.component(.month, from: Date()) - 1
    }

    private var yearMonthLabel: String {
        let year = Calendar.current.component(.year, from: Date())
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        let monthStr = formatter.string(from: Date()).uppercased()
        return "\(year) \u{00B7} \(monthStr)"
    }

    private func buildCells() -> [Int] {
        let calendar = Calendar.current
        let now = Date()
        guard let yearStart = calendar.date(from: calendar.dateComponents([.year], from: now)) else {
            return Array(repeating: 0, count: rows * cols)
        }

        let maxCount = max(1, dailyMap.values.max() ?? 1)

        var cells: [Int] = []
        for week in 0..<cols {
            for dayOfWeek in 0..<rows {
                let dayOffset = week * 7 + dayOfWeek
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: yearStart) else {
                    cells.append(0)
                    continue
                }
                let day = calendar.startOfDay(for: date)
                let count = dailyMap[day] ?? 0
                let normalized = Double(count) / Double(maxCount)
                let intensity: Int
                if count == 0 {
                    intensity = 0
                } else if normalized < 0.25 {
                    intensity = 1
                } else if normalized < 0.5 {
                    intensity = 2
                } else if normalized < 0.75 {
                    intensity = 3
                } else {
                    intensity = 4
                }
                cells.append(intensity)
            }
        }
        return cells
    }

    private func cellColor(for intensity: Int) -> Color {
        if intensity == 0 {
            return Color.primary.opacity(0.06)
        }
        let opacity = 0.15 + Double(intensity) * 0.18
        return themeStore.accentColor.opacity(opacity)
    }
}
