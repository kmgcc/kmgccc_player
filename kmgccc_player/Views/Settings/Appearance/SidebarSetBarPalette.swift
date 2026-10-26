import MotionKit
import SwiftUI

/// Two-row palette: a real glass button and a compact name in each capsule.
struct SidebarSetBarPalette: View {
    let rows: [[SidebarSetBarItemKind]]
    let buttonCount: Int
    let pendingKind: SidebarSetBarItemKind?
    let reservedKind: SidebarSetBarItemKind?
    let returningKind: SidebarSetBarItemKind?
    let scrollTarget: SidebarSetBarItemKind?
    let coordinateSpace: Namespace.ID
    let onAdd: (SidebarSetBarItemKind) -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    static let initialRows = SidebarSetBarPaletteLayout.initialRows

    private var kinds: [SidebarSetBarItemKind] { rows.flatMap { $0 } }

    var body: some View {
        ScrollViewReader { proxy in
            HorizontalFadeScrollContainer(
                spacing: 10,
                fadeWidth: 16,
                verticalPadding: 4,
                leadingScrollPadding: 8,
                trailingScrollPadding: 8,
                showsScrollButtons: true,
                scrollButtonLeadingInset: 4,
                scrollButtonTrailingInset: 4
            ) {
                // Eager placement also measures offscreen return targets before landing.
                SidebarSetBarPaletteLayout(rows: rows) {
                    ForEach(kinds) { kind in
                        candidate(kind, isReserved: reservedKind == kind, isReturning: returningKind == kind)
                            .id(kind)
                    }
                }
                .motionAnimation(.layout, value: rows)
            }
            .onChange(of: scrollTarget) { _, kind in
                guard let kind else { return }
                // Scroll first; measured geometry then drives the MotionKit flight.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo(kind, anchor: .center) }
            }
        }
        .frame(height: SidebarSetBarPaletteLayout.contentHeight + 8)
        .sidebarSetBarFrame(.palette, in: coordinateSpace)
    }

    private func candidate(_ kind: SidebarSetBarItemKind, isReserved: Bool, isReturning: Bool) -> some View {
        let isEnabled = kind == .separator
            ? buttonCount >= 2
            : buttonCount < SidebarSetBarConfiguration.maximumButtonCount
        return HStack(spacing: 10) {
            SidebarSetBarButton(kind: kind) { if isEnabled { onAdd(kind) } }
                .opacity(pendingKind == kind || isReserved ? 0 : 1)
                .overlay {
                    if pendingKind == kind && !isReturning {
                        SidebarSetBarDropTarget(tint: themeStore.accentColor)
                    }
                }
                .sidebarSetBarFrame(.candidate(kind), in: coordinateSpace)

            Text(kind.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                .frame(width: SidebarSetBarPaletteLayout.labelWidth(for: kind), alignment: .leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(width: SidebarSetBarPaletteLayout.cardWidth(for: kind), height: 52)
        .background(themeStore.appForegroundPalette.secondaryColor.opacity(0.06), in: Capsule())
        .overlay {
            if isReturning {
                SidebarSetBarDropTarget(tint: themeStore.accentColor)
                    .transition(.opacity)
            }
        }
        .contentShape(Capsule())
        .sidebarSetBarFrame(.candidateCard(kind), in: coordinateSpace)
        .opacity(isEnabled || pendingKind == kind ? 1 : 0.4)
    }
}

private struct SidebarSetBarPaletteLayout: Layout {
    let rows: [[SidebarSetBarItemKind]]

    private var kinds: [SidebarSetBarItemKind] { rows.flatMap { $0 } }

    static let contentHeight: CGFloat = 112
    private static let rowSpacing: CGFloat = 10
    private static let firstRowY: CGFloat = 0
    private static let secondRowY: CGFloat = 60

    static func labelWidth(for kind: SidebarSetBarItemKind) -> CGFloat {
        CGFloat(min(kind.title.count, 6)) * 14
    }

    static func cardWidth(for kind: SidebarSetBarItemKind) -> CGFloat {
        8 + GlassStyleTokens.headerControlHeight + 10 + labelWidth(for: kind) + 12
    }

    private static let orderedKinds: [SidebarSetBarItemKind] = {
        var kinds = SidebarSetBarItemKind.allCases.filter { $0 != .separator }
        kinds.insert(.separator, at: min(3, kinds.count))
        return kinds
    }()

    private static let stableRowByKind: [SidebarSetBarItemKind: Int] = {
        let allKinds = orderedKinds
        let weights = allKinds.map { Int((cardWidth(for: $0) + rowSpacing).rounded()) }
        let total = weights.reduce(0, +)
        var reachable: Set<Int> = [0]
        var paths: [Int: [SidebarSetBarItemKind]] = [0: []]

        for (kind, weight) in zip(allKinds, weights) {
            let previousSums = reachable.sorted()
            for sum in previousSums {
                let next = sum + weight
                guard paths[next] == nil else { continue }
                paths[next] = (paths[sum] ?? []) + [kind]
                reachable.insert(next)
            }
        }

        let rowZeroWeight = paths.keys
            .filter { $0 > 0 && $0 < total }
            .sorted()
            .min { abs(total - 2 * $0) < abs(total - 2 * $1) } ?? total / 2
        let rowZeroKinds = Set(paths[rowZeroWeight] ?? [])
        return Dictionary(uniqueKeysWithValues: allKinds.map { ($0, rowZeroKinds.contains($0) ? 0 : 1) })
    }()

    static let initialRows: [[SidebarSetBarItemKind]] = (0..<2).map { row in
        orderedKinds.filter { stableRowByKind[$0] == row }
    }

    private func rowWidths() -> [CGFloat] {
        rows.map { row in
            row.enumerated().reduce(CGFloat.zero) { width, element in
                width + (element.offset == 0 ? 0 : Self.rowSpacing) + Self.cardWidth(for: element.element)
            }
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = rowWidths()
        return CGSize(width: widths.max() ?? 0, height: Self.contentHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let displayedKinds = kinds
        for row in rows.indices {
            var nextX = bounds.minX
            for kind in rows[row] {
                guard let index = displayedKinds.firstIndex(of: kind), index < subviews.count else { continue }
                subviews[index].place(
                    at: CGPoint(
                        x: nextX,
                        y: bounds.minY + (row == 0 ? Self.firstRowY : Self.secondRowY)
                    ),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: Self.cardWidth(for: kind), height: 52)
                )
                nextX += Self.cardWidth(for: kind) + Self.rowSpacing
            }
        }
    }
}
