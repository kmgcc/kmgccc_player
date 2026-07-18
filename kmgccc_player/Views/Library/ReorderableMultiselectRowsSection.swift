//
//  ReorderableMultiselectRowsSection.swift
//  myPlayer2
//
//  Shared multiselect + manual reorder shell for library row lists.
//

import AppKit
import SwiftUI

struct ReorderableMultiselectRowsSection<Row, RowContent, FloatingContent>: View
where Row: Identifiable, Row.ID == UUID, RowContent: View, FloatingContent: View {
    let rows: [Row]
    let isMultiselectMode: Bool
    let selectedIDs: Set<UUID>
    let canReorder: Bool
    let isSearchFiltering: Bool
    let coordinateSpaceName: String
    let rowCornerRadius: CGFloat
    let bottomSpacerHeight: CGFloat
    let badgeText: (Int) -> String
    let rowHeight: (Row) -> CGFloat
    let onClearSelection: () -> Void
    let onBeginReorder: () -> Void
    let onEndReorder: () -> Void
    let onCommitOrder: (_ orderedIDs: [UUID]) -> Void
    @ViewBuilder let rowContent: (Row, Bool, TrackRowSelectionContinuity) -> RowContent
    @ViewBuilder let floatingContent: (Row) -> FloatingContent

    @Environment(\.colorScheme) private var colorScheme

    @State private var visualOrderIDs: [UUID]?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var dragContainerWidth: CGFloat = 0
    @State private var draggingID: UUID?
    @State private var draggedIDs: [UUID] = []
    @State private var dragStartOrderedIDs: [UUID] = []
    @State private var dragStartAnchorY: CGFloat = 0
    @State private var dragFloatingX: CGFloat = 0
    @State private var dragFloatingY: CGFloat = 0
    @State private var dragLastTargetIndex: Int = 0
    @State private var dragInsertionIndex: Int?
    @State private var dragCardYOffsetByID: [UUID: CGFloat] = [:]
    @State private var dragPointerYOffset: CGFloat = 0
    @State private var dragGlassOpacity: Double = 0
    @State private var dragDidReorder = false
    @State private var isFinishingDrag = false
    @State private var enclosingScrollView: NSScrollView?
    @State private var reorderCoordinateView: NSView?
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var autoScrollVelocity: CGFloat = 0

    private let dragHorizontalDamping: CGFloat = 0.45
    private let dragHorizontalLimit: CGFloat = 28
    private let autoScrollEdgeThreshold: CGFloat = 118
    private let autoScrollBottomEdgeThreshold: CGFloat = 176
    private let autoScrollMaxVelocity: CGFloat = 500
    private let autoScrollMinVelocity: CGFloat = 22
    private let autoScrollFrameInterval: UInt64 = 16_000_000
    private let maxVisibleDraggedCards = 5
    private let pileCardOverlap: CGFloat = 12
    private let pileHorizontalJitter: CGFloat = 5

    private var dragReorderAnimation: Animation {
        .spring(response: 0.30, dampingFraction: 0.88, blendDuration: 0.04)
    }

    private var dragSettleAnimation: Animation {
        .spring(response: 0.38, dampingFraction: 0.90, blendDuration: 0.04)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            selectedRunBackgrounds
                .allowsHitTesting(false)

            LazyVStack(spacing: 0) {
                ForEach(displayRows) { row in
                    rowContainer(row)
                        .background(rowFrameReporter(for: row.id))
                }
                Color.clear.frame(height: bottomSpacerHeight)
            }
            .scrollTargetLayout()
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { dragContainerWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newValue in
                            dragContainerWidth = newValue
                        }
                }
            )
            .coordinateSpace(name: coordinateSpaceName)
            .background(
                ReorderableEnclosingScrollViewReader { scrollView, coordinateView in
                    enclosingScrollView = scrollView
                    reorderCoordinateView = coordinateView
                }
            )
            .onPreferenceChange(ReorderableRowFramePreferenceKey.self) { frames in
                // Merge instead of replace: LazyVStack stops reporting frames
                // for recycled (off-screen) rows, and a full replace would
                // drop them. Frames are measured in the stack's own coordinate
                // space, whose origin does not move with scrolling, so a
                // recycled row's last-known frame stays accurate and the
                // selection-run background can keep spanning it. Stale entries
                // for removed rows are purged in the rows-id onChange below.
                rowFrames.merge(frames, uniquingKeysWith: { _, new in new })
            }

            if let rect = dragPlaceholderRect, !isFinishingDrag {
                RoundedRectangle(cornerRadius: rowCornerRadius + 2)
                    .strokeBorder(
                        Color.accentColor.opacity(0.72),
                        style: StrokeStyle(
                            lineWidth: 2.2,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: [8, 6]
                        )
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(5)
            }

            if draggingID != nil {
                floatingDragGroup
                    .frame(width: dragContainerWidth, alignment: .topLeading)
                    .offset(x: dragFloatingX, y: dragFloatingY)
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
        .background(
            MultiselectExitKeyMonitor(
                isEnabled: isMultiselectMode,
                onEscape: {
                    if draggingID != nil {
                        cancelDrag()
                    } else {
                        onClearSelection()
                    }
                },
                onReturn: {
                    guard draggingID == nil else { return }
                    onClearSelection()
                }
            )
        )
        .onExitCommand {
            if draggingID != nil {
                cancelDrag()
            } else if isMultiselectMode {
                onClearSelection()
            }
        }
        .onDisappear {
            cancelDrag()
            stopAutoScroll()
        }
        .onChange(of: rows.map(\.id)) { _, newIDs in
            // Purge cached frames for rows that no longer exist so the merge
            // above cannot leave ghost frames behind after deletions. Pure
            // scrolling does not change rows.map(\.id), so this does not fire
            // on scroll and cached off-screen frames survive.
            let validIDs = Set(newIDs)
            rowFrames = rowFrames.filter { validIDs.contains($0.key) }
            if draggingID == nil {
                visualOrderIDs = nil
            } else if !isFinishingDrag {
                cancelDrag()
            }
        }
        .onChange(of: isMultiselectMode) { _, isEnabled in
            if !isEnabled {
                cancelDrag()
            }
        }
        .onChange(of: isSearchFiltering) { _, isFiltering in
            if isFiltering {
                cancelDrag()
            }
        }
    }

    private var isReorderEnabled: Bool {
        isMultiselectMode
            && canReorder
            && !isSearchFiltering
            && rows.count > 1
    }

    private var rowLookup: [UUID: Row] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    private var displayedOrderIDs: [UUID] {
        let source = rows.map(\.id)
        guard let visualOrderIDs else { return source }
        let validIDs = Set(source)
        let ordered = visualOrderIDs.filter { validIDs.contains($0) }
        guard ordered.count == source.count else { return source }
        return ordered
    }

    private var displayRows: [Row] {
        let lookup = rowLookup
        return displayedOrderIDs.compactMap { lookup[$0] }
    }

    private var draggedRows: [Row] {
        let lookup = rowLookup
        return draggedIDs.compactMap { lookup[$0] }
    }

    private var visibleDraggedRows: [Row] {
        Array(draggedRows.prefix(maxVisibleDraggedCards))
    }

    private var draggedIDSet: Set<UUID> {
        Set(draggedIDs)
    }

    private var selectedBackgroundFill: Color {
        Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.15)
    }

    private var selectedRuns: [(first: UUID, ids: [UUID])] {
        guard isMultiselectMode else { return [] }
        var activeSelectedIDs = selectedIDs
        if draggingID != nil {
            activeSelectedIDs.subtract(draggedIDSet)
        }
        guard !activeSelectedIDs.isEmpty else { return [] }

        var runs: [(first: UUID, ids: [UUID])] = []
        var currentRun: [UUID] = []
        for id in displayedOrderIDs {
            if activeSelectedIDs.contains(id) {
                currentRun.append(id)
            } else if !currentRun.isEmpty {
                runs.append((first: currentRun[0], ids: currentRun))
                currentRun = []
            }
        }
        if !currentRun.isEmpty {
            runs.append((first: currentRun[0], ids: currentRun))
        }
        return runs
    }

    private var dragPlaceholderRect: CGRect? {
        guard draggingID != nil, !draggedIDs.isEmpty else { return nil }
        let frames = draggedIDs.compactMap { rowFrames[$0] }
        guard let firstFrame = frames.first else { return nil }
        let union = frames.dropFirst().reduce(firstFrame) { partial, frame in
            partial.union(frame)
        }
        let insetX: CGFloat = 4
        let insetY: CGFloat = 5
        return CGRect(
            x: insetX,
            y: union.minY + insetY,
            width: max(0, dragContainerWidth - insetX * 2),
            height: max(0, union.height - insetY * 2)
        )
    }

    private var dragGroupHeight: CGFloat {
        guard !visibleDraggedRows.isEmpty else { return 0 }
        let visibleCount = max(1, min(draggedRows.count, maxVisibleDraggedCards))
        let maxRowHeight = visibleDraggedRows.map(rowHeight).max() ?? 0
        return maxRowHeight + CGFloat(visibleCount - 1) * pileCardOverlap + 16
    }

    private var insertionIndicatorY: CGFloat? {
        guard draggingID != nil, let dragInsertionIndex else { return nil }
        let remaining = displayedOrderIDs.filter { !draggedIDSet.contains($0) }
        if remaining.isEmpty {
            return dragFloatingY
        }
        if dragInsertionIndex < remaining.count,
           let frame = rowFrames[remaining[dragInsertionIndex]] {
            return frame.minY
        }
        if dragInsertionIndex > 0,
           let frame = rowFrames[remaining[dragInsertionIndex - 1]] {
            return frame.maxY
        }
        if let first = remaining.first,
           let frame = rowFrames[first] {
            return frame.minY
        }
        return nil
    }

    private var selectedRunBackgrounds: some View {
        ZStack(alignment: .topLeading) {
            ForEach(selectedRuns, id: \.first) { run in
                if let rect = selectedRunRect(run) {
                    RoundedRectangle(cornerRadius: rowCornerRadius)
                        .fill(selectedBackgroundFill)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
    }

    private func selectedRunRect(_ run: (first: UUID, ids: [UUID])) -> CGRect? {
        guard
            let firstID = run.ids.first,
            let lastID = run.ids.last,
            let firstFrame = rowFrames[firstID],
            let lastFrame = rowFrames[lastID]
        else { return nil }

        return CGRect(
            x: 0,
            y: firstFrame.minY,
            width: dragContainerWidth,
            height: max(0, lastFrame.maxY - firstFrame.minY)
        )
    }

    private var floatingDragGroup: some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(draggedRows.enumerated()), id: \.element.id) { depth, row in
                    let settling = isFinishingDrag
                    let pileDepth = min(depth, maxVisibleDraggedCards - 1)
                    let pileX = settling ? 0 : pileXOffset(for: row.id, depth: pileDepth)
                    let pileY = settling ? 0 : pileYOffset(pileDepth)
                    floatingRowCard(row)
                        .frame(
                            width: dragContainerWidth,
                            height: rowHeight(row),
                            alignment: .topLeading
                        )
                        .offset(x: pileX, y: pileY)
                        .offset(y: dragCardYOffsetByID[row.id] ?? 0)
                        .rotationEffect(
                            .degrees(settling ? 0 : pileRotationDegrees(for: row.id, depth: pileDepth)),
                            anchor: .center
                        )
                        .opacity(settling || depth < maxVisibleDraggedCards ? 1 : 0)
                        .zIndex(Double(draggedRows.count - depth))
                }
            }
            .frame(height: dragGroupHeight, alignment: .topLeading)
            .shadow(
                color: GlassStyleTokens.subtleShadowColor,
                radius: GlassStyleTokens.subtleShadowRadius + 5,
                x: 0,
                y: 5
            )

            if draggedIDs.count > 1 && !isFinishingDrag {
                Text(badgeText(draggedIDs.count))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: 5, y: -6)
            }
        }
    }

    private func floatingRowCard(_ row: Row) -> some View {
        let shape = RoundedRectangle(cornerRadius: rowCornerRadius)
        return floatingContent(row)
            .frame(
                width: dragContainerWidth,
                height: rowHeight(row),
                alignment: .topLeading
            )
            .background(
                shape
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.72))
                    .glassEffect(.regular, in: shape)
                    .opacity(dragGlassOpacity)
            )
            .overlay(
                shape
                    .strokeBorder(Color.white.opacity(0.16 * dragGlassOpacity), lineWidth: 0.8)
            )
            .clipShape(shape)
    }

    private func rowContainer(_ row: Row) -> some View {
        let isDragged = draggingID != nil && draggedIDSet.contains(row.id)
        return ZStack {
            rowPlaceholder()
                .opacity(isDragged ? 1 : 0)
            rowContent(row, selectedIDs.contains(row.id), selectionContinuity(for: row.id))
                .opacity(isDragged ? 0 : 1)
        }
        .contentShape(Rectangle())
        .reorderableMultiselectGesture(
            isReorderEnabled,
            reorderGesture(for: row)
        )
    }

    private func rowPlaceholder() -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    private func rowFrameReporter(for id: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ReorderableRowFramePreferenceKey.self,
                value: [id: proxy.frame(in: .named(coordinateSpaceName))]
            )
        }
    }

    private func reorderGesture(for row: Row) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(coordinateSpaceName))
            .onChanged { value in
                if draggingID != row.id {
                    beginDrag(from: row.id, initialLocationY: value.location.y)
                }
                guard draggingID == row.id else { return }

                dragFloatingY = floatingTopY(for: value)
                dragFloatingX = max(
                    -dragHorizontalLimit,
                    min(dragHorizontalLimit, value.translation.width * dragHorizontalDamping)
                )

                let centerY = dragFloatingY + dragGroupHeight / 2
                updateAutoScroll(forCenterY: centerY)
                updateDragTarget(forCenterY: centerY)
            }
            .onEnded { _ in
                endDrag()
            }
    }

    private func beginDrag(from id: UUID, initialLocationY: CGFloat?) {
        let startOrder = displayedOrderIDs
        guard startOrder.contains(id) else { return }

        let groupIDs: [UUID]
        if selectedIDs.contains(id) {
            groupIDs = startOrder.filter { selectedIDs.contains($0) }
        } else {
            groupIDs = [id]
        }
        guard !groupIDs.isEmpty else { return }

        onBeginReorder()
        visualOrderIDs = startOrder
        draggingID = id
        draggedIDs = groupIDs
        dragStartOrderedIDs = startOrder
        dragStartAnchorY = rowFrames[id]?.minY ?? 0
        let fallbackHeight = rowLookup[id].map(rowHeight) ?? 0
        let initialPointerY = currentMouseYInReorderSpace()
            ?? initialLocationY
            ?? dragStartAnchorY + fallbackHeight / 2
        dragPointerYOffset = initialPointerY - dragStartAnchorY
        dragFloatingY = dragStartAnchorY
        dragFloatingX = 0
        dragGlassOpacity = 0
        dragDidReorder = false
        isFinishingDrag = false

        let draggedSet = Set(groupIDs)
        let remaining = startOrder.filter { !draggedSet.contains($0) }
        let originalTarget = insertionIndexForCurrentGroup(
            groupIDs: groupIDs,
            in: startOrder,
            remaining: remaining
        )
        dragLastTargetIndex = originalTarget
        dragInsertionIndex = originalTarget

        var gatherOffsets: [UUID: CGFloat] = [:]
        for (depth, itemID) in groupIDs.enumerated() {
            let pileDepth = min(depth, maxVisibleDraggedCards - 1)
            let sourceY = rowFrames[itemID]?.minY ?? dragStartAnchorY + pileYOffset(pileDepth)
            gatherOffsets[itemID] = sourceY - dragStartAnchorY - pileYOffset(pileDepth)
        }
        dragCardYOffsetByID = gatherOffsets
        withAnimation(dragReorderAnimation) {
            dragCardYOffsetByID = [:]
            dragGlassOpacity = 1
        }
    }

    private func moveDraggedRows(to targetIndex: Int) {
        guard let visualOrderIDs else { return }
        let draggedSet = Set(draggedIDs)
        var remaining = visualOrderIDs.filter { !draggedSet.contains($0) }
        let index = max(0, min(remaining.count, targetIndex))
        remaining.insert(contentsOf: draggedIDs, at: index)
        guard remaining != visualOrderIDs else { return }
        dragDidReorder = true
        withAnimation(dragReorderAnimation) {
            self.visualOrderIDs = remaining
        }
    }

    private func endDrag() {
        guard draggingID != nil else { return }
        stopAutoScroll()
        let finalOrder = visualOrderIDs ?? rows.map(\.id)
        let shouldCommit = dragDidReorder && finalOrder != dragStartOrderedIDs

        if shouldCommit {
            onCommitOrder(finalOrder)
        }

        settleDrag(commitSucceeded: shouldCommit)
    }

    private func settleDrag(commitSucceeded: Bool) {
        guard let draggingID else { return }
        let settledOrder = visualOrderIDs
        let finalY = finalDraggedGroupTopY() ?? insertionIndicatorY ?? dragFloatingY
        let settleOffsets = finalDraggedCardYOffsets(groupTopY: finalY)
        withAnimation(dragSettleAnimation) {
            isFinishingDrag = true
            dragFloatingX = 0
            dragFloatingY = finalY
            dragCardYOffsetByID = settleOffsets
            dragGlassOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            guard isFinishingDrag, self.draggingID == draggingID else { return }
            let keepVisualOrder = commitSucceeded
                && settledOrder != nil
                && rows.map(\.id) != settledOrder
            clearDragState(keepVisualOrder: keepVisualOrder)
        }
    }

    private func cancelDrag() {
        guard draggingID != nil else { return }
        stopAutoScroll()
        withAnimation(dragSettleAnimation) {
            visualOrderIDs = dragStartOrderedIDs.isEmpty ? nil : dragStartOrderedIDs
            dragFloatingX = 0
            dragFloatingY = dragStartAnchorY
            dragGlassOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            guard !isFinishingDrag else { return }
            clearDragState(keepVisualOrder: false)
        }
    }

    private func clearDragState(keepVisualOrder: Bool) {
        if !keepVisualOrder {
            visualOrderIDs = nil
        }
        draggingID = nil
        draggedIDs = []
        dragStartOrderedIDs = []
        dragStartAnchorY = 0
        dragPointerYOffset = 0
        dragFloatingX = 0
        dragFloatingY = 0
        dragLastTargetIndex = 0
        dragInsertionIndex = nil
        dragCardYOffsetByID = [:]
        dragGlassOpacity = 0
        dragDidReorder = false
        isFinishingDrag = false
        stopAutoScroll()
        onEndReorder()
    }

    private func targetInsertionIndex(forCenterY centerY: CGFloat) -> Int {
        let remaining = displayedOrderIDs.filter { !draggedIDSet.contains($0) }
        guard !remaining.isEmpty else { return 0 }

        let visibleRows = remaining.enumerated().compactMap { index, id -> (index: Int, frame: CGRect)? in
            guard let frame = rowFrames[id] else { return nil }
            return (index, frame)
        }
        guard let firstVisible = visibleRows.first else {
            return max(0, min(remaining.count, dragLastTargetIndex))
        }

        if centerY < firstVisible.frame.midY {
            return firstVisible.index
        }

        for visible in visibleRows where centerY < visible.frame.midY {
            return visible.index
        }

        if let lastVisible = visibleRows.last {
            return min(remaining.count, lastVisible.index + 1)
        }
        return remaining.count
    }

    private func insertionIndexForCurrentGroup(
        groupIDs: [UUID],
        in order: [UUID],
        remaining: [UUID]
    ) -> Int {
        guard let firstDraggedIndex = order.firstIndex(where: { groupIDs.contains($0) }) else {
            return 0
        }
        let removedBefore = order[..<firstDraggedIndex].filter { groupIDs.contains($0) }.count
        return max(0, min(remaining.count, firstDraggedIndex - removedBefore))
    }

    private func updateDragTarget(forCenterY centerY: CGFloat) {
        let target = targetInsertionIndex(forCenterY: centerY)
        dragInsertionIndex = target
        guard target != dragLastTargetIndex else { return }
        dragLastTargetIndex = target
        moveDraggedRows(to: target)
    }

    private func updateAutoScroll(forCenterY centerY: CGFloat) {
        let velocity = autoScrollVelocity(forCenterY: centerY)
        autoScrollVelocity = velocity
        if abs(velocity) > 0.5 {
            startAutoScrollIfNeeded()
        } else {
            stopAutoScroll()
        }
    }

    private func autoScrollVelocity(forCenterY centerY: CGFloat) -> CGFloat {
        guard
            let viewport = visibleViewportInReorderSpace(),
            let scrollBounds = autoScrollOriginBounds()
        else { return 0 }

        let canScrollUp = scrollBounds.originY > scrollBounds.minY + 0.5
        let canScrollDown = scrollBounds.originY < scrollBounds.maxY - 0.5

        let topRatio = max(0, min(1, (autoScrollEdgeThreshold - (centerY - viewport.minY)) / autoScrollEdgeThreshold))
        let bottomRatio = max(0, min(1, (autoScrollBottomEdgeThreshold - (viewport.maxY - centerY)) / autoScrollBottomEdgeThreshold))

        if canScrollUp, topRatio > bottomRatio, topRatio > 0 {
            return -scaledAutoScrollVelocity(for: topRatio)
        }
        if canScrollDown, bottomRatio > 0 {
            return scaledAutoScrollVelocity(for: bottomRatio)
        }
        return 0
    }

    private func scaledAutoScrollVelocity(for ratio: CGFloat) -> CGFloat {
        let eased = pow(Double(ratio), 1.7)
        return autoScrollMinVelocity
            + (autoScrollMaxVelocity - autoScrollMinVelocity) * CGFloat(eased)
    }

    private func startAutoScrollIfNeeded() {
        guard autoScrollTask == nil else { return }
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                performAutoScrollStep()
                try? await Task.sleep(nanoseconds: autoScrollFrameInterval)
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        autoScrollVelocity = 0
    }

    private func performAutoScrollStep() {
        guard draggingID != nil, abs(autoScrollVelocity) > 0.5 else {
            stopAutoScroll()
            return
        }

        let delta = scrollEnclosingScrollView(by: autoScrollVelocity / 60)
        guard abs(delta) > 0.05 else {
            stopAutoScroll()
            return
        }

        if let mouseY = currentMouseYInReorderSpace() {
            dragFloatingY = mouseY - dragPointerYOffset
        }
        let centerY = dragFloatingY + dragGroupHeight / 2
        updateDragTarget(forCenterY: centerY)
        updateAutoScroll(forCenterY: centerY)
    }

    @discardableResult
    private func scrollEnclosingScrollView(by delta: CGFloat) -> CGFloat {
        guard
            let scrollView = enclosingScrollView,
            let documentView = scrollView.documentView
        else { return 0 }

        let clipView = scrollView.contentView
        let oldOrigin = clipView.bounds.origin
        let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
        let minY = delta < 0 ? min(maxY, minimumAutoScrollOriginY(in: documentView)) : 0
        guard delta >= 0 || oldOrigin.y > minY + 0.05 else { return 0 }
        let newY = max(minY, min(maxY, oldOrigin.y + delta))
        guard abs(newY - oldOrigin.y) > 0.05 else { return 0 }

        clipView.scroll(to: NSPoint(x: oldOrigin.x, y: newY))
        scrollView.reflectScrolledClipView(clipView)
        return newY - oldOrigin.y
    }

    private func visibleViewportInReorderSpace() -> CGRect? {
        guard
            let scrollView = enclosingScrollView,
            let documentView = scrollView.documentView,
            let coordinateView = reorderCoordinateView
        else { return nil }

        let viewport = coordinateView
            .convert(scrollView.contentView.documentVisibleRect, from: documentView)
            .standardized
        let clippedViewport = viewport.intersection(coordinateView.bounds).standardized
        guard !clippedViewport.isNull, clippedViewport.height > 0 else { return nil }
        return clippedViewport
    }

    private func autoScrollOriginBounds() -> (originY: CGFloat, minY: CGFloat, maxY: CGFloat)? {
        guard
            let scrollView = enclosingScrollView,
            let documentView = scrollView.documentView
        else { return nil }

        let clipView = scrollView.contentView
        let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
        let minY = min(maxY, minimumAutoScrollOriginY(in: documentView))
        return (clipView.bounds.origin.y, minY, maxY)
    }

    private func finalDraggedGroupTopY() -> CGFloat? {
        guard let firstDraggedID = draggedIDs.first else { return nil }
        return rowFrames[firstDraggedID]?.minY
    }

    private func finalDraggedCardYOffsets(groupTopY: CGFloat) -> [UUID: CGFloat] {
        var offsets: [UUID: CGFloat] = [:]
        for id in draggedIDs {
            if let frame = rowFrames[id] {
                offsets[id] = frame.minY - groupTopY
            }
        }
        return offsets
    }

    private func floatingTopY(for value: DragGesture.Value) -> CGFloat {
        let pointerY = currentMouseYInReorderSpace() ?? value.location.y
        return pointerY - dragPointerYOffset
    }

    private func currentMouseYInReorderSpace() -> CGFloat? {
        guard
            let coordinateView = reorderCoordinateView,
            let window = coordinateView.window
        else { return nil }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return coordinateView.convert(windowPoint, from: nil).y
    }

    private func minimumAutoScrollOriginY(in documentView: NSView) -> CGFloat {
        guard let coordinateView = reorderCoordinateView else { return 0 }
        let rect = coordinateView.convert(coordinateView.bounds, to: documentView)
        return max(0, rect.minY)
    }

    private func selectionContinuity(for id: UUID) -> TrackRowSelectionContinuity {
        guard isMultiselectMode, selectedIDs.contains(id) else {
            return .isolated
        }
        let order = displayedOrderIDs
        guard let index = order.firstIndex(of: id) else { return .isolated }
        let connectsToPrevious = index > 0 && selectedIDs.contains(order[index - 1])
        let connectsToNext = index + 1 < order.count && selectedIDs.contains(order[index + 1])
        return TrackRowSelectionContinuity(
            connectsToPrevious: connectsToPrevious,
            connectsToNext: connectsToNext
        )
    }

    private func pileYOffset(_ depth: Int) -> CGFloat {
        CGFloat(depth) * pileCardOverlap
    }

    private func pileXOffset(for id: UUID, depth: Int) -> CGFloat {
        guard depth > 0 else { return 0 }
        let seed = pileSeed(for: id)
        let normalized = CGFloat((seed % 7) - 3) / 3
        return normalized * pileHorizontalJitter
    }

    private func pileRotationDegrees(for id: UUID, depth: Int) -> Double {
        guard depth > 0 else { return 0 }
        let seed = pileSeed(for: id)
        let sign: Double = seed.isMultiple(of: 2) ? 1 : -1
        return sign * (1.2 + Double(seed % 11) * 0.18)
    }

    private func pileSeed(for id: UUID) -> Int {
        id.uuidString.unicodeScalars.reduce(0) { partial, scalar in
            partial &+ Int(scalar.value)
        }
    }
}

private struct ReorderableEnclosingScrollViewReader: NSViewRepresentable {
    let onResolve: (NSScrollView?, NSView?) -> Void

    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveSoon()
    }

    final class ResolverView: NSView {
        var onResolve: ((NSScrollView?, NSView?) -> Void)?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveSoon()
        }

        func resolveSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onResolve?(enclosingScrollView(), self)
            }
        }

        private func enclosingScrollView() -> NSScrollView? {
            var view = superview
            while let current = view {
                if let scrollView = current as? NSScrollView {
                    return scrollView
                }
                view = current.superview
            }
            return nil
        }
    }
}

struct MultiselectExitKeyMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onEscape: () -> Void
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.update(
            isEnabled: isEnabled,
            onEscape: onEscape,
            onReturn: onReturn
        )
        context.coordinator.install()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            isEnabled: isEnabled,
            onEscape: onEscape,
            onReturn: onReturn
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        private var monitor: Any?
        private var isEnabled = false
        private var onEscape: () -> Void = {}
        private var onReturn: () -> Void = {}

        func update(
            isEnabled: Bool,
            onEscape: @escaping () -> Void,
            onReturn: @escaping () -> Void
        ) {
            self.isEnabled = isEnabled
            self.onEscape = onEscape
            self.onReturn = onReturn
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard isEnabled, !isTextInputActive(for: event) else { return event }
            switch event.keyCode {
            case 36, 76:
                onReturn()
                return nil
            case 53:
                onEscape()
                return nil
            default:
                return event
            }
        }

        private func isTextInputActive(for event: NSEvent) -> Bool {
            guard let responder = event.window?.firstResponder else { return false }
            if responder is NSTextView || responder is NSTextField {
                return true
            }
            return String(describing: type(of: responder)).contains("FieldEditor")
        }
    }
}

private struct ReorderableRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    @ViewBuilder
    func reorderableMultiselectGesture<G: Gesture>(_ enabled: Bool, _ gesture: G) -> some View {
        if enabled {
            highPriorityGesture(gesture)
        } else {
            self
        }
    }
}
