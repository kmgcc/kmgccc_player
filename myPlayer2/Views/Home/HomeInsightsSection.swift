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
    var mode: HomeLayoutMode = .wide
    /// Actual content width for the page. Used so we can stack vertically when
    /// the side-by-side ranking + calendar would otherwise crowd each other.
    var containerWidth: CGFloat = 0

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader
            statsRow
            insightsColumns
                .padding(.top, 4)
        }
    }

    private var stacksVertically: Bool {
        // Switch to vertical layout when ranking + calendar would crowd.
        // 820pt is a comfortable side-by-side floor.
        if containerWidth > 0 { return containerWidth < 820 }
        return mode == .compact || mode == .narrow
    }

    @ViewBuilder
    private var insightsColumns: some View {
        if stacksVertically {
            VStack(alignment: .leading, spacing: 14) {
                HomePreferenceRankingView(items: homeVM.preferenceRanking)
                    .frame(maxWidth: .infinity)
                HomeListeningHeatmapView(dailyMap: homeVM.dailyListeningMap)
                    .frame(maxWidth: .infinity)
            }
        } else {
            // Capped at 380, never less than 300, otherwise ~36% of width.
            let dynamic = containerWidth > 0 ? containerWidth * 0.36 : 360
            let heatmapWidth = min(max(dynamic, 300), 380)
            HStack(alignment: .top, spacing: 16) {
                HomePreferenceRankingView(items: homeVM.preferenceRanking)
                    .frame(maxWidth: .infinity)
                HomeListeningHeatmapView(dailyMap: homeVM.dailyListeningMap)
                    .frame(width: heatmapWidth)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("听歌记录")
                .font(.system(size: mode.sectionTitleFontSize, weight: .semibold))
                .tracking(-0.3)
            Spacer()
        }
    }

    @ViewBuilder
    private var statsRow: some View {
        let cards: [AnyView] = [
            AnyView(HomeStatCard(
                label: "总歌曲",
                value: "\(homeVM.totalTrackCount)",
                unit: "首",
                subtitle: "音乐库"
            )),
            AnyView(HomeStatCard(
                label: "总播放",
                value: formattedNumber(homeVM.totalPlayCount),
                unit: "次",
                subtitle: "累计"
            )),
            AnyView(HomeStatCard(
                label: "播放时长",
                value: "\(Int(homeVM.totalListeningSeconds / 3600))",
                unit: "小时",
                subtitle: "今年"
            )),
            AnyView(favoriteArtistCard)
        ]

        let columnCount: Int = {
            switch mode {
            case .wide:    return 4
            case .medium:  return 4
            case .compact: return 2
            case .narrow:  return 2
            }
        }()
        let spacing: CGFloat = mode == .narrow ? 10 : 14
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
        LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(cards.indices, id: \.self) { index in
                cards[index]
            }
        }
    }

    private var favoriteArtistCard: some View {
        HomeInsightsCardContainer {
            VStack(alignment: .leading, spacing: 8) {
                Text("常听歌手")
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
                        Text("\(homeVM.favoriteArtistAlbumCount) 张专辑")
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
                    Text("暂无足够的听歌数据")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    // Header row
                    HStack {
                        Text("#")
                            .frame(width: 28)
                        Text("歌曲 \u{00B7} 歌手")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("偏好度")
                            .frame(width: 120)
                        Text("播放")
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

// MARK: - Listening Heatmap (3-month compact calendar)

struct HomeListeningHeatmapView: View {
    let dailyMap: [Date: Int]

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday
        return cal
    }()

    private let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]
    private let cellSpacing: CGFloat = 4
    private let cellSize: CGFloat = 30

    var body: some View {
        HomeInsightsCardContainer {
            VStack(alignment: .leading, spacing: 12) {
                header

                VStack(alignment: .center, spacing: cellSpacing) {
                    weekdayHeader
                    calendarGrid
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(2)
        }
    }

    private var header: some View {
        HStack {
            Text("听歌日历")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text(monthLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var monthLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy 年 M 月"
        return formatter.string(from: Date())
    }

    @ViewBuilder
    private var weekdayHeader: some View {
        HStack(spacing: cellSpacing) {
            ForEach(weekdayLabels.indices, id: \.self) { i in
                Text(weekdayLabels[i])
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: cellSize, height: 14)
            }
        }
    }

    @ViewBuilder
    private var calendarGrid: some View {
        let weeks = buildWeeks()
        VStack(alignment: .leading, spacing: cellSpacing) {
            ForEach(weeks.indices, id: \.self) { i in
                weekRow(weeks[i])
            }
        }
    }

    @ViewBuilder
    private func weekRow(_ week: [DayCell]) -> some View {
        HStack(spacing: cellSpacing) {
            ForEach(week.indices, id: \.self) { i in
                dayView(week[i])
            }
        }
    }

    @ViewBuilder
    private func dayView(_ cell: DayCell) -> some View {
        let cornerRadius: CGFloat = cellSize * 0.3
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(cellFillColor(for: cell.intensity, isCurrentMonth: cell.isCurrentMonth))

            // Today indicator only on current-month dates.
            if cell.isCurrentMonth, cell.isToday {
                Circle()
                    .strokeBorder(themeStore.accentColor.opacity(0.8), lineWidth: 1.4)
                    .frame(width: cellSize - 4, height: cellSize - 4)
            }

            Text("\(cell.dayNumber)")
                .font(.system(
                    size: 11,
                    weight: cell.isCurrentMonth && cell.isToday ? .semibold : .regular
                ))
                .foregroundStyle(cellTextColor(for: cell))
        }
        // Adjacent-month cells are drawn faintly and softly blurred so the
        // current month stays visually anchored.
        .opacity(cell.isCurrentMonth ? 1.0 : 0.18)
        .blur(radius: cell.isCurrentMonth ? 0 : 0.6)
        .frame(width: cellSize, height: cellSize)
    }

    private func cellFillColor(for intensity: Int, isCurrentMonth: Bool) -> Color {
        if !isCurrentMonth {
            // Very low-key adjacent-month rectangle — no accent color even
            // if the same date has play history, so the eye stays on the
            // current month.
            return Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.04)
        }
        if intensity == 0 {
            return Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.05)
        }
        let baseOpacity = 0.18 + Double(intensity) * 0.18
        return themeStore.accentColor.opacity(baseOpacity)
    }

    private func cellTextColor(for cell: DayCell) -> Color {
        if !cell.isCurrentMonth {
            return Color(nsColor: .secondaryLabelColor)
        }
        if cell.intensity >= 3 { return .white }
        return Color(nsColor: .secondaryLabelColor)
    }

    // MARK: - Data shaping

    private struct DayCell {
        let dayNumber: Int
        let isCurrentMonth: Bool
        let isToday: Bool
        let intensity: Int  // 0..4
    }

    /// Show a sliding 3-month window: trailing half of previous month, the
    /// current month in full, and leading half of next month — assembled into
    /// 7-day weekly rows aligned to the calendar's first weekday.
    private func buildWeeks() -> [[DayCell]] {
        let now = Date()
        let today = calendar.startOfDay(for: now)
        guard
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
            let monthRange = calendar.range(of: .day, in: .month, for: monthStart)
        else {
            return []
        }

        // Window: ~14 days before this month start, end ~14 days into next month
        let windowStartRaw = calendar.date(byAdding: .day, value: -14, to: monthStart) ?? monthStart
        let monthEnd = calendar.date(byAdding: .day, value: monthRange.count - 1, to: monthStart) ?? monthStart
        let windowEndRaw = calendar.date(byAdding: .day, value: 14, to: monthEnd) ?? monthEnd

        // Snap to week boundaries based on firstWeekday
        let windowStart = startOfWeek(for: windowStartRaw)
        let windowEnd = endOfWeek(for: windowEndRaw)

        let maxCount = max(1, dailyMap.values.max() ?? 1)

        var weeks: [[DayCell]] = []
        var cursor = windowStart
        while cursor <= windowEnd {
            var week: [DayCell] = []
            for _ in 0..<7 {
                let day = calendar.startOfDay(for: cursor)
                let isCurrentMonth = calendar.isDate(day, equalTo: monthStart, toGranularity: .month)
                let count = dailyMap[day] ?? 0
                let intensity = intensityFor(count: count, maxCount: maxCount)
                week.append(
                    DayCell(
                        dayNumber: calendar.component(.day, from: day),
                        isCurrentMonth: isCurrentMonth,
                        isToday: calendar.isDate(day, inSameDayAs: today),
                        intensity: intensity
                    )
                )
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            weeks.append(week)
        }
        return weeks
    }

    private func startOfWeek(for date: Date) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: dayStart) // 1...7
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: dayStart) ?? dayStart
    }

    private func endOfWeek(for date: Date) -> Date {
        let start = startOfWeek(for: date)
        return calendar.date(byAdding: .day, value: 6, to: start) ?? date
    }

    private func intensityFor(count: Int, maxCount: Int) -> Int {
        if count == 0 { return 0 }
        let n = Double(count) / Double(maxCount)
        if n < 0.25 { return 1 }
        if n < 0.5 { return 2 }
        if n < 0.75 { return 3 }
        return 4
    }
}
