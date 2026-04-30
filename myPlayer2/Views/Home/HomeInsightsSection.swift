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
    /// Distance from the window's left edge to the center column's left edge
    /// (sidebar width + horizontal padding). Used so the narrow horizontal
    /// summary row can align with the rest of the Home content.
    var centerLeftPad: CGFloat = 0
    /// Distance from the window's right edge inward to the center column.
    var centerRightPad: CGFloat = 0

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    /// Width threshold below which the side-by-side ranking + calendar would
    /// crowd each other and we switch to the horizontal-summary narrow layout.
    private let sideBySideThreshold: CGFloat = 840
    private let compactLayoutSpacing: CGFloat = 12
    private let insightsRowHeight: CGFloat = 360

    var body: some View {
        if stacksVertically {
            narrowLayout
        } else {
            wideLayout
        }
    }

    private var stacksVertically: Bool {
        if containerWidth > 0 { return containerWidth < sideBySideThreshold }
        return mode == .compact || mode == .narrow
    }

    // MARK: - Wide layout

    @ViewBuilder
    private var wideLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader
            ListeningStatsRow(homeVM: homeVM)
            sideBySideInsights
                .padding(.top, 4)
        }
        .padding(.leading, centerLeftPad)
        .padding(.trailing, centerRightPad)
    }

    @ViewBuilder
    private var sideBySideInsights: some View {
        let dynamic = containerWidth > 0 ? containerWidth * 0.34 : 360
        let heatmapWidth = min(max(dynamic, 320), 400)
        HStack(alignment: .top, spacing: 16) {
            HomePreferenceRankingView(
                items: homeVM.preferenceRanking,
                fixedHeight: insightsRowHeight
            )
                .frame(maxWidth: .infinity)
                .frame(height: insightsRowHeight)
                .clipped()
            ListeningCalendarCard(
                dailyMap: homeVM.dailyListeningMap,
                renderWidth: heatmapWidth,
                fixedHeight: insightsRowHeight
            )
            .frame(width: heatmapWidth)
            .frame(height: insightsRowHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Narrow layout

    @ViewBuilder
    private var narrowLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader
                .padding(.leading, centerLeftPad)
                .padding(.trailing, centerRightPad)

            compactSummaryRow
                .padding(.leading, centerLeftPad)
                .padding(.trailing, centerRightPad)

            HomePreferenceRankingView(items: homeVM.preferenceRanking)
                .frame(maxWidth: .infinity)
                .padding(.leading, centerLeftPad)
                .padding(.trailing, centerRightPad)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var compactSummaryRow: some View {
        let metrics = compactSummaryMetrics(for: max(220, containerWidth))

        HStack(alignment: .top, spacing: compactLayoutSpacing) {
            ListeningStatsGridCompact(homeVM: homeVM, cardSize: metrics.statCardSize)
                .frame(width: metrics.statsWidth, height: CompactSummaryRowMetrics.rowHeight)
            compactCalendar(width: metrics.calendarWidth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactSummaryMetrics(
        for containerWidth: CGFloat
    ) -> (statsWidth: CGFloat, calendarWidth: CGFloat, statCardSize: CGSize) {
        let available = max(180, containerWidth - compactLayoutSpacing)
        let minStatsWidth: CGFloat = 150
        let minCalendarWidth: CGFloat = 130
        let idealCalendarWidth: CGFloat = 360
        let maxCalendarWidth: CGFloat = 420

        let calendarWidth: CGFloat
        if available < minStatsWidth + minCalendarWidth {
            calendarWidth = max(96, floor(available * 0.43))
        } else {
            let preferredCalendar = min(
                maxCalendarWidth,
                max(minCalendarWidth, floor(available * 0.42))
            )
            calendarWidth = min(preferredCalendar, idealCalendarWidth)
        }

        let statsWidth = max(88, available - calendarWidth)
        let cardWidth = max(39, floor((statsWidth - CompactSummaryRowMetrics.gridSpacing) / 2))
        let statCardSize = CGSize(
            width: cardWidth,
            height: CompactSummaryRowMetrics.statCardSize.height
        )
        return (statsWidth, calendarWidth, statCardSize)
    }

    private func compactCalendar(width: CGFloat) -> some View {
        ListeningCalendarCard(
            dailyMap: homeVM.dailyListeningMap,
            compact: true,
            renderWidth: width,
            fixedHeight: CompactSummaryRowMetrics.rowHeight
        )
        .frame(width: width, height: CompactSummaryRowMetrics.rowHeight)
    }

    // MARK: - Shared header / stat row

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("听歌记录")
                .font(.system(size: mode.sectionTitleFontSize, weight: .semibold))
                .tracking(-0.3)
            Spacer()
        }
    }

}

// MARK: - Compact summary row metrics

/// Sizes for the narrow-layout horizontal summary row. Centralized so the
/// stat cards, favorite-artist card, and compact calendar share consistent
/// dimensions and the row feels cohesive.
private enum CompactSummaryRowMetrics {
    // The heatmap can span up to 9 week rows in the trailing/leading month
    // window. Keep the compact row tall enough that the right calendar is not
    // squeezed, while preserving the same compact card language.
    static let rowHeight: CGFloat = 268
    static let gridSpacing: CGFloat = 10
    static let statCardSize = CGSize(width: 162, height: 129)
    static let statsGridSize = CGSize(
        width: statCardSize.width * 2 + gridSpacing,
        height: statCardSize.height * 2 + gridSpacing
    )
}

// MARK: - Listening Stats Layouts

private struct ListeningStatsRow: View {
    let homeVM: HomeViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            HomeStatCard(
                label: "总歌曲",
                value: "\(homeVM.totalTrackCount)",
                unit: "首",
                subtitle: "音乐库"
            )
            HomeStatCard(
                label: "总播放",
                value: formattedNumber(homeVM.totalPlayCount),
                unit: "次",
                subtitle: "累计"
            )
            HomeStatCard(
                label: "播放时长",
                value: "\(Int(homeVM.totalListeningSeconds / 3600))",
                unit: "小时",
                subtitle: "今年"
            )
            FavoriteArtistCard(homeVM: homeVM)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ListeningStatsGridCompact: View {
    let homeVM: HomeViewModel
    let cardSize: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: CompactSummaryRowMetrics.gridSpacing) {
            HStack(spacing: CompactSummaryRowMetrics.gridSpacing) {
                HomeStatCard(
                    label: "总歌曲",
                    value: "\(homeVM.totalTrackCount)",
                    unit: "首",
                    subtitle: "音乐库",
                    fixedSize: cardSize,
                    compact: true
                )
                HomeStatCard(
                    label: "总播放",
                    value: formattedNumber(homeVM.totalPlayCount),
                    unit: "次",
                    subtitle: "累计",
                    fixedSize: cardSize,
                    compact: true
                )
            }

            HStack(spacing: CompactSummaryRowMetrics.gridSpacing) {
                HomeStatCard(
                    label: "播放时长",
                    value: "\(Int(homeVM.totalListeningSeconds / 3600))",
                    unit: "小时",
                    subtitle: "今年",
                    fixedSize: cardSize,
                    compact: true
                )
                FavoriteArtistCard(
                    homeVM: homeVM,
                    fixedSize: cardSize,
                    compact: true
                )
            }
        }
        .frame(
            width: cardSize.width * 2 + CompactSummaryRowMetrics.gridSpacing,
            height: cardSize.height * 2 + CompactSummaryRowMetrics.gridSpacing,
            alignment: .topLeading
        )
    }
}

private struct FavoriteArtistCard: View {
    let homeVM: HomeViewModel
    var fixedSize: CGSize? = nil
    var compact: Bool = false

    var body: some View {
        HomeInsightsCardContainer(fixedSize: fixedSize, compact: compact) {
            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                Text("常听歌手")
                    .font(.caption2)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if let name = homeVM.favoriteArtistName {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: compact ? 13 : 15, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                        Text("\(homeVM.favoriteArtistAlbumCount) 张专辑")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
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
    n.formatted(.number)
}

// MARK: - Stat Card

private struct HomeStatCard: View {
    let label: String
    let value: String
    let unit: String
    let subtitle: String
    /// When set, the card uses a fixed width/height instead of stretching to
    /// fill its grid cell. Used by the narrow-layout horizontal summary row.
    var fixedSize: CGSize? = nil
    var compact: Bool = false

    var body: some View {
        HomeInsightsCardContainer(fixedSize: fixedSize, compact: compact) {
            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                Text(label)
                    .font(.caption2)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(.system(size: compact ? 20 : 28, weight: .semibold))
                        .tracking(-0.5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
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
    /// When non-nil the card is locked to this width and height (used in
    /// the narrow-layout horizontal summary row). Otherwise the card
    /// stretches to fill its grid cell with a 100pt minimum height.
    var fixedSize: CGSize? = nil
    var fixedHeight: CGFloat? = nil
    var compact: Bool = false
    var drawsShadow: Bool = true
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .padding(compact ? 12 : 16)
            .frame(
                maxWidth: fixedSize == nil ? .infinity : nil,
                minHeight: fixedSize == nil && fixedHeight == nil ? 100 : nil,
                alignment: .topLeading
            )
            .frame(
                width: fixedSize?.width,
                height: fixedSize?.height ?? fixedHeight,
                alignment: .topLeading
            )
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
                radius: drawsShadow ? 6 : 0,
                y: drawsShadow ? 2 : 0
            )
    }
}

// MARK: - Preference Ranking

private struct HomePreferenceRankingView: View {
    let items: [HomeViewModel.PreferenceRankItem]
    var fixedHeight: CGFloat? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isHeightConstrained = fixedHeight != nil
        let visibleItems = isHeightConstrained ? Array(items.prefix(6)) : items
        let horizontalPadding: CGFloat = isHeightConstrained ? 10 : 12
        let scoreWidth: CGFloat = isHeightConstrained ? 108 : 120
        let playWidth: CGFloat = isHeightConstrained ? 44 : 50

        HomeInsightsCardContainer(fixedHeight: fixedHeight) {
            VStack(spacing: 0) {
                if visibleItems.isEmpty {
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
                            .frame(width: scoreWidth)
                        Text("播放")
                            .frame(width: playWidth, alignment: .trailing)
                    }
                    .font(.caption2)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, isHeightConstrained ? 5 : 8)

                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                        HomeRankRow(
                            rank: index + 1,
                            item: item,
                            dense: isHeightConstrained
                        )
                        if index < visibleItems.count - 1 {
                            Divider()
                                .padding(.horizontal, horizontalPadding)
                        }
                    }
                }
            }
            .padding(.vertical, isHeightConstrained ? 1 : 4)
        }
        .clipped()
    }
}

private struct HomeRankRow: View {
    let rank: Int
    let item: HomeViewModel.PreferenceRankItem
    var dense: Bool = false
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    // Normalize score: preferenceScoreCache can range roughly -100..+100
    private var normalizedScore: Double {
        max(0, min(1, (item.score + 100) / 200))
    }

    var body: some View {
        let rowHorizontalPadding: CGFloat = dense ? 10 : 12
        let scoreColumnWidth: CGFloat = dense ? 108 : 120
        let scoreBarWidth: CGFloat = dense ? 56 : 70
        let scoreBarHeight: CGFloat = dense ? 5 : 6
        let playColumnWidth: CGFloat = dense ? 44 : 50

        HStack(spacing: 0) {
            Text("\(rank)")
                .font(.system(size: dense ? 14 : 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: dense ? 13 : 14, weight: .semibold))
                    .lineLimit(1)
                Text(item.artist)
                    .font(dense ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(themeStore.accentColor.opacity(0.12))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(themeStore.accentColor.opacity(colorScheme == .dark ? 0.7 : 0.55))
                        .frame(width: scoreBarWidth * normalizedScore)
                }
                .frame(width: scoreBarWidth, height: scoreBarHeight)

                Text(String(format: "%.0f", item.score))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
            .frame(width: scoreColumnWidth)

            Text("\(item.playCount)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: playColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, dense ? 5 : 8)
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

// MARK: - Listening Calendar

private let debugCalendarTextAlignment = false

private struct ListeningCalendarCard: View {
    let dailyMap: [Date: Int]
    var compact: Bool = false
    var renderWidth: CGFloat? = nil
    var fixedHeight: CGFloat? = nil

    var body: some View {
        HomeListeningHeatmapView(
            dailyMap: dailyMap,
            compact: compact,
            renderWidth: renderWidth,
            fixedHeight: fixedHeight
        )
    }
}

struct HomeListeningHeatmapView: View {
    let dailyMap: [Date: Int]
    var compact: Bool
    var renderWidth: CGFloat?
    var fixedHeight: CGFloat?

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    private let renderModel: ListeningCalendarRenderModel

    private var headerGridSpacing: CGFloat { compact ? 8 : 12 }

    init(
        dailyMap: [Date: Int],
        compact: Bool = false,
        renderWidth: CGFloat? = nil,
        fixedHeight: CGFloat? = nil
    ) {
        self.dailyMap = dailyMap
        self.compact = compact
        self.renderWidth = renderWidth
        self.fixedHeight = fixedHeight
        self.renderModel = CalendarHeatmapData.build(
            dailyMap: dailyMap,
            compact: compact,
            isDark: false,
            accent: .fallback
        )
    }

    var body: some View {
        let resolvedModel = renderModel.replacing(
            isDark: colorScheme == .dark,
            accent: ListeningCalendarRenderModel.RGBA.resolved(from: themeStore.accentColor)
        )

        HomeInsightsCardContainer(fixedSize: nil, fixedHeight: fixedHeight, drawsShadow: false) {
            VStack(alignment: .leading, spacing: headerGridSpacing) {
                header
                ListeningCalendarRenderView(model: resolvedModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            .padding(compact ? 0 : 2)
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var header: some View {
        HStack {
            Text("听歌日历")
                .font(.system(size: compact ? 12 : 14, weight: .semibold))
            Spacer()
            Text(renderModel.monthTitle)
                .font(.system(size: compact ? 10 : 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

private struct ListeningCalendarRenderView: NSViewRepresentable {
    let model: ListeningCalendarRenderModel

    func makeNSView(context: Context) -> ListeningCalendarNSView {
        let view = ListeningCalendarNSView()
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        view.layer?.needsDisplayOnBoundsChange = true
        view.model = model
        return view
    }

    func updateNSView(_ nsView: ListeningCalendarNSView, context: Context) {
        guard nsView.model != model else { return }
        nsView.model = model
        nsView.needsDisplay = true
    }
}

private final class ListeningCalendarNSView: NSView {
    var model: ListeningCalendarRenderModel?
    private let dayNumberVisualCorrectionY: CGFloat = 0.35

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if oldSize != newSize {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let model else { return }

        let metrics = Metrics(compact: model.isCompact)
        let layout = makeLayout(for: model, metrics: metrics)

        drawWeekdayHeader(
            model.weekdaySymbols,
            layout: layout,
            metrics: metrics
        )
        drawDays(
            model.days,
            layout: layout,
            metrics: metrics,
            model: model
        )
    }

    private func makeLayout(
        for model: ListeningCalendarRenderModel,
        metrics: Metrics
    ) -> CalendarLayout {
        let contentRect = bounds.insetBy(dx: metrics.horizontalInset, dy: metrics.verticalInset)
        let rowCount = max(model.displayRowCount, 1)
        let widthCell = (
            max(contentRect.width, 1) - CGFloat(6) * metrics.cellSpacing
        ) / 7
        let heightCell = (
            max(contentRect.height, 1)
                - metrics.weekdayHeaderHeight
                - metrics.headerGridSpacing
                - CGFloat(max(rowCount - 1, 0)) * metrics.cellSpacing
        ) / CGFloat(rowCount)
        let cellSize = pixelFloor(max(
            metrics.minCellSize,
            min(widthCell, heightCell, metrics.maxCellSize)
        ))
        let gridWidth = 7 * cellSize + 6 * metrics.cellSpacing
        let gridHeight = CGFloat(rowCount) * cellSize
            + CGFloat(max(rowCount - 1, 0)) * metrics.cellSpacing
        let totalHeight = metrics.weekdayHeaderHeight + metrics.headerGridSpacing + gridHeight
        let anchorX = contentRect.midX - gridWidth / 2
        let anchorY = contentRect.midY - totalHeight / 2
        let weekdayRect = CGRect(
            x: pixelRound(anchorX),
            y: pixelRound(max(contentRect.minY, anchorY)),
            width: gridWidth,
            height: metrics.weekdayHeaderHeight
        )
        let gridRect = CGRect(
            x: weekdayRect.minX,
            y: pixelRound(weekdayRect.maxY + metrics.headerGridSpacing),
            width: gridWidth,
            height: gridHeight
        )

        return CalendarLayout(
            contentRect: contentRect,
            weekdayRect: weekdayRect,
            gridRect: gridRect,
            cellSize: cellSize,
            rowCount: rowCount
        )
    }

    private func drawWeekdayHeader(
        _ symbols: [String],
        layout: CalendarLayout,
        metrics: Metrics
    ) {
        let font = NSFont.systemFont(ofSize: metrics.weekdayFontSize, weight: .medium)

        for (index, symbol) in symbols.prefix(7).enumerated() {
            let rect = CGRect(
                x: layout.weekdayRect.minX + CGFloat(index) * (layout.cellSize + metrics.cellSpacing),
                y: layout.weekdayRect.minY,
                width: layout.cellSize,
                height: layout.weekdayRect.height
            )
            drawCenteredText(
                symbol,
                font: font,
                color: secondaryTextColor(alpha: 0.72),
                in: rect
            )
        }
    }

    private func drawDays(
        _ days: [ListeningCalendarRenderModel.Day],
        layout: CalendarLayout,
        metrics: Metrics,
        model: ListeningCalendarRenderModel
    ) {
        let cornerRadius = layout.cellSize * 0.3
        let fontSize = min(
            metrics.maxDateFontSize,
            max(metrics.minDateFontSize, layout.cellSize * 0.42)
        )

        for day in days {
            let rect = CGRect(
                x: layout.gridRect.minX + CGFloat(day.column) * (layout.cellSize + metrics.cellSpacing),
                y: layout.gridRect.minY + CGFloat(day.row) * (layout.cellSize + metrics.cellSpacing),
                width: layout.cellSize,
                height: layout.cellSize
            )

            let pillRect = rect

            cellFillColor(for: day, model: model).setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

            if day.isCurrentMonth, day.isToday {
                model.accent.nsColor(alpha: 0.8).setStroke()
                let ring = NSBezierPath(ovalIn: pillRect.insetBy(dx: 2, dy: 2))
                ring.lineWidth = 1.4
                ring.stroke()
            }

            let font = NSFont.systemFont(
                ofSize: fontSize,
                weight: day.isCurrentMonth && day.isToday ? .semibold : .regular
            )
            drawCenteredDayNumber(
                "\(day.dayNumber)",
                font: font,
                color: textColor(for: day),
                in: pillRect
            )
        }
    }

    private func cellFillColor(
        for day: ListeningCalendarRenderModel.Day,
        model: ListeningCalendarRenderModel
    ) -> NSColor {
        if !day.isCurrentMonth {
            return baseColor(isDark: model.isDark, alpha: model.isDark ? 0.026 : 0.02)
        }
        if day.intensity == 0 {
            return baseColor(isDark: model.isDark, alpha: model.isDark ? 0.06 : 0.05)
        }
        return model.accent.nsColor(alpha: 0.18 + day.intensity * 0.72)
    }

    private func textColor(for day: ListeningCalendarRenderModel.Day) -> NSColor {
        if !day.isCurrentMonth {
            return secondaryTextColor(alpha: 0.18)
        }
        if day.intensity >= 0.75 { return .white }
        return secondaryTextColor(alpha: 0.88)
    }

    private func drawCenteredText(
        _ text: String,
        font: NSFont,
        color: NSColor,
        in rect: CGRect
    ) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color
        ])
        let size = attributed.size()
        let x = pixelRound(rect.midX - size.width / 2)
        let fontCenterOffset = (font.ascender + font.descender) / 2
        let baselineY = rect.midY - fontCenterOffset
        let y = pixelRound(baselineY - font.ascender)
        attributed.draw(at: CGPoint(x: x, y: y))
    }

    private func drawCenteredDayNumber(
        _ text: String,
        font: NSFont,
        color: NSColor,
        in rect: CGRect
    ) {
        let string = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let size = string.size(withAttributes: attributes)
        let x = pixelRound(rect.midX - size.width / 2)
        let y = pixelRound(rect.midY - size.height / 2 + dayNumberVisualCorrectionY)
        let textRect = CGRect(origin: CGPoint(x: x, y: y), size: size)

        string.draw(at: textRect.origin, withAttributes: attributes)
        drawTextAlignmentDebug(in: rect, textRect: textRect, baselineY: y + font.ascender)
    }

    private func drawTextAlignmentDebug(in cellRect: CGRect, textRect: CGRect, baselineY: CGFloat) {
        guard debugCalendarTextAlignment else { return }

        NSColor.systemRed.withAlphaComponent(0.75).setStroke()
        let cellPath = NSBezierPath(rect: cellRect)
        cellPath.lineWidth = 0.5
        cellPath.stroke()

        NSColor.systemBlue.withAlphaComponent(0.65).setStroke()
        let centerLine = NSBezierPath()
        centerLine.move(to: CGPoint(x: cellRect.minX, y: cellRect.midY))
        centerLine.line(to: CGPoint(x: cellRect.maxX, y: cellRect.midY))
        centerLine.lineWidth = 0.5
        centerLine.stroke()

        NSColor.systemGreen.withAlphaComponent(0.75).setStroke()
        let textPath = NSBezierPath(rect: textRect)
        textPath.lineWidth = 0.5
        textPath.stroke()

        NSColor.systemOrange.withAlphaComponent(0.75).setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: CGPoint(x: cellRect.minX, y: baselineY))
        baseline.line(to: CGPoint(x: cellRect.maxX, y: baselineY))
        baseline.lineWidth = 0.5
        baseline.stroke()
    }

    private func baseColor(isDark: Bool, alpha: Double) -> NSColor {
        NSColor(calibratedWhite: isDark ? 1 : 0, alpha: CGFloat(alpha))
    }

    private func secondaryTextColor(alpha: Double) -> NSColor {
        NSColor.secondaryLabelColor.withAlphaComponent(CGFloat(alpha))
    }

    private func pixelRound(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return (value * scale).rounded() / scale
    }

    private func pixelFloor(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return floor(value * scale) / scale
    }

    private struct CalendarLayout {
        let contentRect: CGRect
        let weekdayRect: CGRect
        let gridRect: CGRect
        let cellSize: CGFloat
        let rowCount: Int
    }

    private struct Metrics {
        let horizontalInset: CGFloat
        let verticalInset: CGFloat
        let cellSpacing: CGFloat
        let headerGridSpacing: CGFloat
        let weekdayHeaderHeight: CGFloat
        let weekdayFontSize: CGFloat
        let minCellSize: CGFloat
        let maxCellSize: CGFloat
        let minDateFontSize: CGFloat
        let maxDateFontSize: CGFloat

        init(compact: Bool) {
            horizontalInset = compact ? 0 : 4
            verticalInset = 0
            cellSpacing = compact ? 2 : 4
            headerGridSpacing = compact ? 8 : 12
            weekdayHeaderHeight = compact ? 11 : 14
            weekdayFontSize = compact ? 9 : 11
            minCellSize = compact ? 9 : 18
            maxCellSize = compact ? 28 : 36
            minDateFontSize = compact ? 7 : 9
            maxDateFontSize = compact ? 10 : 12
        }
    }
}

private struct ListeningCalendarRenderModel: Equatable {
    struct Day: Equatable {
        let dayNumber: Int
        let column: Int
        let row: Int
        let intensity: Double
        let isToday: Bool
        let isCurrentMonth: Bool
    }

    struct RGBA: Equatable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        static let fallback = RGBA(red: 0.35, green: 0.48, blue: 0.82, alpha: 1)

        static func resolved(from color: Color) -> RGBA {
            let resolved = NSColor(color)
            guard let rgb = resolved.usingColorSpace(.deviceRGB) else {
                return .fallback
            }
            return RGBA(
                red: Double(rgb.redComponent),
                green: Double(rgb.greenComponent),
                blue: Double(rgb.blueComponent),
                alpha: Double(rgb.alphaComponent)
            )
        }

        func nsColor(alpha overrideAlpha: Double? = nil) -> NSColor {
            NSColor(
                calibratedRed: CGFloat(red),
                green: CGFloat(green),
                blue: CGFloat(blue),
                alpha: CGFloat(overrideAlpha ?? alpha)
            )
        }
    }

    let monthTitle: String
    let weekdaySymbols: [String]
    let days: [Day]
    let isCompact: Bool
    let displayRowCount: Int
    let isDark: Bool
    let accent: RGBA

    func replacing(isDark: Bool, accent: RGBA) -> ListeningCalendarRenderModel {
        ListeningCalendarRenderModel(
            monthTitle: monthTitle,
            weekdaySymbols: weekdaySymbols,
            days: days,
            isCompact: isCompact,
            displayRowCount: displayRowCount,
            isDark: isDark,
            accent: accent
        )
    }
}

private enum CalendarHeatmapData {
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        return cal
    }()

    private static let compactMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M"
        return formatter
    }()

    private static let regularMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy 年 M 月"
        return formatter
    }()

    static func build(
        dailyMap: [Date: Int],
        compact: Bool,
        isDark: Bool,
        accent: ListeningCalendarRenderModel.RGBA
    ) -> ListeningCalendarRenderModel {
        let now = Date()
        let monthLabel = makeMonthLabel(for: now, compact: compact)
        let today = calendar.startOfDay(for: now)
        guard
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
        else {
            return ListeningCalendarRenderModel(
                monthTitle: monthLabel,
                weekdaySymbols: weekdayLabels,
                days: [],
                isCompact: compact,
                displayRowCount: displayRowCount(compact: compact),
                isDark: isDark,
                accent: accent
            )
        }

        var normalizedDailyMap: [Date: Int] = [:]
        normalizedDailyMap.reserveCapacity(dailyMap.count)
        for (date, count) in dailyMap {
            normalizedDailyMap[calendar.startOfDay(for: date), default: 0] += count
        }
        let maxCount = max(1, normalizedDailyMap.values.max() ?? 1)
        let compactStart = startOfWeek(for: monthStart)
        let currentMonthID = calendar.dateComponents([.year, .month], from: monthStart)
        let rowCount = displayRowCount(compact: compact)
        let windowStart = displayStartDate(compactStart: compactStart, compact: compact)

        var days: [ListeningCalendarRenderModel.Day] = []
        days.reserveCapacity(rowCount * 7)
        var cursor = windowStart
        for row in 0..<rowCount {
            for column in 0..<7 {
                let day = calendar.startOfDay(for: cursor)
                let count = normalizedDailyMap[day] ?? 0
                days.append(
                    ListeningCalendarRenderModel.Day(
                        dayNumber: calendar.component(.day, from: day),
                        column: column,
                        row: row,
                        intensity: intensityFor(count: count, maxCount: maxCount),
                        isToday: calendar.isDate(day, inSameDayAs: today),
                        isCurrentMonth: calendar.dateComponents([.year, .month], from: day) == currentMonthID
                    )
                )
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
        }

        return ListeningCalendarRenderModel(
            monthTitle: monthLabel,
            weekdaySymbols: weekdayLabels,
            days: days,
            isCompact: compact,
            displayRowCount: rowCount,
            isDark: isDark,
            accent: accent
        )
    }

    private static let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

    private static func displayRowCount(compact: Bool) -> Int {
        compact ? 6 : 7
    }

    private static func displayStartDate(compactStart: Date, compact: Bool) -> Date {
        if compact { return compactStart }
        return calendar.date(byAdding: .day, value: -7, to: compactStart) ?? compactStart
    }

    private static func makeMonthLabel(for date: Date, compact: Bool) -> String {
        (compact ? compactMonthFormatter : regularMonthFormatter).string(from: date)
    }

    private static func startOfWeek(for date: Date) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: dayStart)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: dayStart) ?? dayStart
    }

    private static func intensityFor(count: Int, maxCount: Int) -> Double {
        if count == 0 { return 0 }
        let n = Double(count) / Double(maxCount)
        if n < 0.25 { return 0.25 }
        if n < 0.5 { return 0.5 }
        if n < 0.75 { return 0.75 }
        return 1
    }
}
