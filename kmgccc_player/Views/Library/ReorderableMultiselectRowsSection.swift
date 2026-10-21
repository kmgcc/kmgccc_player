//
//  ReorderableMultiselectRowsSection.swift
//  myPlayer2
//
//  Shared multiselect + manual reorder shell for library row lists.
//

import AppKit
import MotionKit
import Observation
import SwiftUI

struct ReorderableMultiselectRowsSection<Row, RowContent, FloatingContent>: View
where Row: Identifiable, Row.ID == UUID, RowContent: View, FloatingContent: View {
    let rows: [Row]
    let isMultiselectMode: Bool
    let selectedIDs: Set<UUID>
    let canReorder: Bool
    /// Track lists can carry their cards out of the list to drop targets.
    /// The pile then draws in the window layer, which spans every pane.
    var trackDragPayload: (([UUID]) -> LibraryTrackDragPayload)? = nil
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var visualOrderIDs: [UUID]?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var dragContainerWidth: CGFloat = 0
    @State private var draggingID: UUID?
    @State private var draggedIDs: [UUID] = []
    @State private var dragStartOrderedIDs: [UUID] = []
    @State private var dragStartRowFrames: [UUID: CGRect] = [:]
    @State private var dragStartAnchorY: CGFloat = 0
    @State private var dragStartTargetIndex: Int = 0
    @State private var dragFloatingX: CGFloat = 0
    @State private var dragFloatingY: CGFloat = 0
    @State private var dragLastTargetIndex: Int = 0
    @State private var dragInsertionIndex: Int?
    @State private var dragCardPresentation = ReorderableFloatingCardsPresentation()
    @State private var dragPointerXOffset: CGFloat = 0
    @State private var dragPointerYOffset: CGFloat = 0
    @State private var dragDidReorder = false
    @State private var enclosingScrollView: NSScrollView?
    @State private var reorderCoordinateView: NSView?
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var autoScrollVelocity: CGFloat = 0
    @State private var dragWindowSession: LibraryTrackDragWindowSession?
    @State private var dragOverlayID: UUID?
    /// The pointer left the list or rests on a drop target: reordering pauses
    /// and the rows keep their original order.
    @State private var isDragOutsideList = false
    /// Released on a drop target; the window is applying the drop.
    @State private var isAwaitingDrop = false
    @State private var cancelledUntilMouseUp = false
    @GestureState private var isPointerDragging = false

    private let dragHorizontalDamping: CGFloat = 0.45
    private let dragHorizontalLimit: CGFloat = 28
    private let autoScrollEdgeThreshold: CGFloat = 118
    private let autoScrollBottomEdgeThreshold: CGFloat = 176
    private let autoScrollMaxVelocity: CGFloat = 2000
    private let autoScrollOverdriveMaxVelocity: CGFloat = 2800
    private let autoScrollMinVelocity: CGFloat = 30
    private let autoScrollFrameInterval: UInt64 = 16_000_000
    private let maxVisibleDraggedCards = 5
    private let pileCardOverlap: CGFloat = 12
    private let pileHorizontalJitter: CGFloat = 5

    private var motionPolicy: MotionPolicy {
        configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
    }

    private var dragReorderAnimation: Animation? {
        motionPolicy.animation(for: motionTokens[.control])
    }

    private func dragSettleAnimation(initialVelocity: Double = 0) -> Animation? {
        motionPolicy.animation(
            for: motionTokens[.gestureSettle],
            initialVelocity: initialVelocity
        )
    }

    private var isFinishingDrag: Bool {
        get { dragCardPresentation.isFinishing }
        nonmutating set { dragCardPresentation.isFinishing = newValue }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isMultiselectMode {
                selectedRunBackgrounds
                    .allowsHitTesting(false)
            }

            LazyVStack(spacing: 0) {
                if !isMultiselectMode && draggingID == nil {
                    ForEach(rows) { row in
                        rowContent(row, selectedIDs.contains(row.id), .isolated)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Expose the model-derived extent at the lazy-stack
                            // boundary so realized and estimated rows share the
                            // same height contract.
                            .frame(height: rowHeight(row), alignment: .leading)
                            .contentShape(Rectangle())
                    }
                } else {
                    ForEach(displayRows) { row in
                        rowContainer(row)
                            .frame(height: rowHeight(row), alignment: .topLeading)
                            .background(rowFrameReporter(for: row.id))
                    }
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
                        themeStore.accentColor.opacity(0.72),
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
                    .motionAnimation(.gestureSettle, value: dragPlaceholderRect != nil)
                    .zIndex(5)
            }

            // The window layer draws the same pile while a track drag is active.
            if draggingID != nil && dragOverlayID == nil {
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
                        if !isAwaitingDrop { cancelDrag() }
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
                if !isAwaitingDrop { cancelDrag() }
            } else if isMultiselectMode {
                onClearSelection()
            }
        }
        .onDisappear {
            if dragOverlayID != nil {
                clearDragState(keepVisualOrder: false)
            } else {
                cancelDrag()
            }
            stopAutoScroll()
        }
        .onChange(of: isMultiselectMode ? rows.map(\.id) : []) { _, newIDs in
            // Row frames are only consumed by multiselect. Avoid rebuilding
            // the full ID snapshot during ordinary long-list scrolling.
            // Purge cached frames for rows that no longer exist so the merge
            // above cannot leave ghost frames behind after deletions. Pure
            // scrolling in multiselect does not change rows.map(\.id), so
            // cached off-screen frames survive.
            let validIDs = Set(newIDs)
            rowFrames = rowFrames.filter { validIDs.contains($0.key) }
            if draggingID == nil {
                visualOrderIDs = nil
            } else if !isFinishingDrag && !isAwaitingDrop {
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
        .onChange(of: isPointerDragging) { _, dragging in
            if !dragging { cancelledUntilMouseUp = false }
        }
    }

    private var isReorderEnabled: Bool {
        isMultiselectMode
            && canReorder
            && !isSearchFiltering
            && rows.count > 1
    }

    private var isRowDragEnabled: Bool {
        isReorderEnabled || (isMultiselectMode && trackDragPayload != nil)
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
        guard visualOrderIDs != nil else { return rows }
        let lookup = rowLookup
        return displayedOrderIDs.compactMap { lookup[$0] }
    }

    private var draggedRows: [Row] {
        let lookup = rowLookup
        // The card the pointer picked up stays on top. Payload and committed
        // order still use draggedIDs, which remains in the list's order.
        let cardIDs = draggingID.map { id in [id] + draggedIDs.filter { $0 != id } } ?? draggedIDs
        return cardIDs.compactMap { lookup[$0] }
    }

    private var visibleDraggedRows: [Row] {
        Array(draggedRows.prefix(maxVisibleDraggedCards))
    }

    private var draggedIDSet: Set<UUID> {
        Set(draggedIDs)
    }

    private var selectedBackgroundFill: Color {
        themeStore.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.15)
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
        let presentation = dragCardPresentation
        return ReorderableFloatingCards(
            presentation: presentation,
            width: dragContainerWidth,
            height: dragGroupHeight,
            cornerRadius: rowCornerRadius,
            backgroundColor: themeStore.backgroundColor,
            accentColor: themeStore.accentColor,
            badge: badgeText(draggedIDs.count),
            maxVisibleCards: maxVisibleDraggedCards,
            onMount: { gatherCardsAfterMount(presentation) }
        )
    }

    @ViewBuilder
    private func rowContainer(_ row: Row) -> some View {
        let isSelected = selectedIDs.contains(row.id)
        let continuity = selectionContinuity(for: row.id)

        if !isMultiselectMode && draggingID == nil {
            rowContent(row, isSelected, continuity)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        } else {
            let isDragged = draggingID != nil && draggedIDSet.contains(row.id)
            ZStack {
                rowPlaceholder()
                    .opacity(isDragged ? 1 : 0)
                rowContent(row, isSelected, continuity)
                    .opacity(isDragged ? 0 : 1)
            }
            .contentShape(Rectangle())
            .reorderableMultiselectGesture(
                isRowDragEnabled,
                reorderGesture(for: row)
            )
        }
    }

    private func rowPlaceholder() -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func rowFrameReporter(for id: UUID) -> some View {
        if isMultiselectMode {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ReorderableRowFramePreferenceKey.self,
                    value: [id: proxy.frame(in: .named(coordinateSpaceName))]
                )
            }
        }
    }

    private func reorderGesture(for row: Row) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(coordinateSpaceName))
            .updating($isPointerDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                guard !cancelledUntilMouseUp, !isFinishingDrag, !isAwaitingDrop else { return }
                if draggingID != row.id {
                    beginDrag(from: row.id, initialLocation: value.location)
                }
                guard draggingID == row.id else { return }

                dragFloatingY = floatingTopY(for: value)
                if dragOverlayID != nil {
                    // Leaving the list must keep the grabbed point under the
                    // pointer, so the pile follows it on both axes.
                    dragFloatingX = floatingLeadingX(for: value)
                } else {
                    dragFloatingX = max(
                        -dragHorizontalLimit,
                        min(dragHorizontalLimit, value.translation.width * dragHorizontalDamping)
                    )
                }

                if dragOverlayID != nil {
                    let isOverTarget = publishFloatingDrag()
                    setDragOutsideList(isOverTarget || !isPointerWithinList)
                    guard !isDragOutsideList else { return }
                }
                guard isReorderEnabled else { return }

                let centerY = dragFloatingY + dragGroupHeight / 2
                updateAutoScroll(forCenterY: centerY)
                updateDragTarget(forCenterY: centerY)
            }
            .onEnded { value in
                defer { cancelledUntilMouseUp = false }
                guard !cancelledUntilMouseUp, !isFinishingDrag, !isAwaitingDrop, draggingID == row.id else { return }
                if let dragOverlayID, let dragWindowSession {
                    if dragWindowSession.releaseSourceDrag(dragOverlayID) {
                        isAwaitingDrop = true
                        stopAutoScroll()
                        return
                    }
                    if isDragOutsideList || !isPointerWithinList {
                        cancelDrag()
                        return
                    }
                }
                endDrag(releaseVelocity: value.velocity.height)
            }
    }

    private func beginDrag(from id: UUID, initialLocation: CGPoint?) {
        if trackDragPayload != nil,
           reorderCoordinateView?.window?.libraryTrackDragSession.hasActiveDrag == true {
            return
        }
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
        dragStartRowFrames = rowFrames
        dragStartAnchorY = rowFrames[id]?.minY ?? 0
        let fallbackHeight = rowLookup[id].map(rowHeight) ?? 0
        let initialPointer = currentMouseLocationInReorderSpace()
        let initialPointerY = initialPointer?.y
            ?? initialLocation?.y
            ?? dragStartAnchorY + fallbackHeight / 2
        dragPointerYOffset = fallbackHeight / 2
        dragPointerXOffset = initialPointer?.x ?? initialLocation?.x ?? 0
        dragFloatingY = initialPointerY - dragPointerYOffset
        dragFloatingX = 0
        dragDidReorder = false
        isDragOutsideList = false
        isAwaitingDrop = false

        let draggedSet = Set(groupIDs)
        let remaining = startOrder.filter { !draggedSet.contains($0) }
        let originalTarget = insertionIndexForCurrentGroup(
            groupIDs: groupIDs,
            in: startOrder,
            remaining: remaining
        )
        dragStartTargetIndex = originalTarget
        dragLastTargetIndex = originalTarget
        dragInsertionIndex = originalTarget

        let cards = draggedRows.enumerated().map { depth, row in
            let pileDepth = min(depth, maxVisibleDraggedCards - 1)
            return ReorderableFloatingCard(
                id: row.id,
                content: AnyView(floatingContent(row)),
                height: rowHeight(row),
                pileX: pileXOffset(for: row.id, depth: pileDepth),
                pileY: pileYOffset(pileDepth),
                pileRotation: pileRotationDegrees(for: row.id, depth: pileDepth),
                depth: depth
            )
        }
        let gatherOffsets = Dictionary(uniqueKeysWithValues: cards.map { card in
            (card.id, (rowFrames[card.id]?.minY ?? dragStartAnchorY) - dragFloatingY)
        })
        dragCardPresentation = ReorderableFloatingCardsPresentation(cards: cards, offsets: gatherOffsets)
        beginWindowDrag(groupIDs: groupIDs)
    }

    private func gatherCardsAfterMount(_ presentation: ReorderableFloatingCardsPresentation) {
        guard !presentation.hasMounted else { return }
        presentation.hasMounted = true
        // Wait until this renderer has mounted in its actual hosting view.
        // Its first layout shows each card at the source row before gathering.
        DispatchQueue.main.async {
            guard dragCardPresentation === presentation,
                  draggingID != nil, !isFinishingDrag, !isAwaitingDrop else { return }
            presentation.animation = dragReorderAnimation
            withAnimation(dragReorderAnimation) {
                presentation.offsets = [:]
                presentation.pileProgress = 1
                presentation.glassOpacity = 1
            }
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

    /// A provisional reorder never survives the pointer leaving the list: the
    /// rows slide back, and resume following the pile when it returns.
    private func setDragOutsideList(_ isOutside: Bool) {
        guard isDragOutsideList != isOutside else { return }
        isDragOutsideList = isOutside
        guard isOutside else { return }
        stopAutoScroll()
        dragLastTargetIndex = dragStartTargetIndex
        dragInsertionIndex = dragStartTargetIndex
        dragDidReorder = false
        if visualOrderIDs != dragStartOrderedIDs, !dragStartOrderedIDs.isEmpty {
            withAnimation(dragReorderAnimation) {
                visualOrderIDs = dragStartOrderedIDs
            }
        }
    }

    private func endDrag(releaseVelocity: CGFloat) {
        guard draggingID != nil else { return }
        stopAutoScroll()
        let finalOrder = visualOrderIDs ?? rows.map(\.id)
        let shouldCommit = dragDidReorder && finalOrder != dragStartOrderedIDs

        if shouldCommit {
            onCommitOrder(finalOrder)
        }

        settleDrag(
            commitSucceeded: shouldCommit,
            releaseVelocity: releaseVelocity
        )
    }

    private func settleDrag(commitSucceeded: Bool, releaseVelocity: CGFloat = 0) {
        guard let draggingID else { return }
        let settledOrder = visualOrderIDs
        let finalY = finalDraggedGroupTopY() ?? insertionIndicatorY ?? dragFloatingY
        let settleOffsets = finalDraggedCardYOffsets(groupTopY: finalY)
        let initialVelocity = MotionSpec.clampedInitialVelocity(
            MotionSpec.normalizedInitialVelocity(
                from: dragFloatingY,
                to: finalY,
                velocity: Double(releaseVelocity)
            )
        )
        dragCardPresentation.animation = dragSettleAnimation(initialVelocity: initialVelocity)
        withAnimation(dragSettleAnimation(initialVelocity: initialVelocity)) {
            isFinishingDrag = true
            dragFloatingX = 0
            dragFloatingY = finalY
            dragCardPresentation.offsets = settleOffsets
            dragCardPresentation.pileProgress = 0
            dragCardPresentation.glassOpacity = 0
        }
        if let dragOverlayID { dragWindowSession?.settleSourceDrag(dragOverlayID) }
        publishFloatingDrag(animation: dragSettleAnimation(initialVelocity: initialVelocity))

        let cleanupDelay = motionPolicy.visualCompletionDelay(
            for: motionTokens[.gestureSettle],
            initialVelocity: initialVelocity
        )
        let clearDrag: @MainActor @Sendable () -> Void = {
            guard isFinishingDrag, self.draggingID == draggingID else { return }
            let keepVisualOrder = commitSucceeded
                && settledOrder != nil
                && rows.map(\.id) != settledOrder
            clearDragState(keepVisualOrder: keepVisualOrder)
        }
        if cleanupDelay <= .leastNonzeroMagnitude {
            clearDrag()
        } else {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + cleanupDelay,
                execute: clearDrag
            )
        }
    }

    /// Restores the original order and sends every card back to its own row
    /// at full size.
    private func cancelDrag() {
        guard let cancelledID = draggingID, !isFinishingDrag else { return }
        // A cancel during the gesture ignores the rest of it; a cancel after
        // mouse-up (a rejected drop) must not swallow the next drag.
        cancelledUntilMouseUp = NSEvent.pressedMouseButtons & 1 != 0
        isAwaitingDrop = false
        stopAutoScroll()
        let returnOffsets = Dictionary(uniqueKeysWithValues: draggedIDs.map { id in
            (id, (dragStartRowFrames[id]?.minY ?? dragStartAnchorY) - dragStartAnchorY)
        })
        dragCardPresentation.animation = dragSettleAnimation()
        withAnimation(dragSettleAnimation()) {
            isFinishingDrag = true
            visualOrderIDs = dragStartOrderedIDs.isEmpty ? nil : dragStartOrderedIDs
            dragFloatingX = 0
            dragFloatingY = dragStartAnchorY
            dragCardPresentation.offsets = returnOffsets
            dragCardPresentation.pileProgress = 0
            dragCardPresentation.glassOpacity = 0
        }
        if let dragOverlayID { dragWindowSession?.settleSourceDrag(dragOverlayID) }
        publishFloatingDrag(animation: dragSettleAnimation())

        let cleanupDelay = motionPolicy.visualCompletionDelay(
            for: motionTokens[.gestureSettle]
        )
        let clearDrag: @MainActor @Sendable () -> Void = {
            guard self.draggingID == cancelledID, isFinishingDrag else { return }
            clearDragState(keepVisualOrder: false)
        }
        if cleanupDelay <= .leastNonzeroMagnitude {
            clearDrag()
        } else {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + cleanupDelay,
                execute: clearDrag
            )
        }
    }

    private func clearDragState(keepVisualOrder: Bool) {
        guard draggingID != nil else { return }
        if let dragOverlayID { dragWindowSession?.endSourceDrag(dragOverlayID) }
        dragOverlayID = nil
        dragWindowSession = nil
        if !keepVisualOrder {
            visualOrderIDs = nil
        }
        draggingID = nil
        draggedIDs = []
        dragStartOrderedIDs = []
        dragStartRowFrames = [:]
        dragStartAnchorY = 0
        dragStartTargetIndex = 0
        dragPointerXOffset = 0
        dragPointerYOffset = 0
        dragFloatingX = 0
        dragFloatingY = 0
        dragLastTargetIndex = 0
        dragInsertionIndex = nil
        // A successful external drop keeps rendering the old object while it
        // sinks into its target. Only the source's reference is reset here.
        dragCardPresentation = ReorderableFloatingCardsPresentation()
        dragDidReorder = false
        isDragOutsideList = false
        isAwaitingDrop = false
        stopAutoScroll()
        onEndReorder()
    }

    // MARK: - Window layer

    private var windowDragContent: AnyView {
        AnyView(
            floatingDragGroup
                .frame(width: dragContainerWidth, alignment: .topLeading)
                .environmentObject(themeStore)
                .environment(\.libraryPresentedAccentColor, themeStore.accentColor)
                .tint(themeStore.accentColor)
                .accentColor(themeStore.accentColor)
                .environment(\.colorScheme, colorScheme)
                .environment(\.motionTokens, motionTokens)
                .environment(\.motionPolicy, configuredMotionPolicy)
        )
    }

    private var windowDragFrame: CGRect {
        CGRect(x: dragFloatingX, y: dragFloatingY, width: dragContainerWidth, height: dragGroupHeight)
    }

    private func beginWindowDrag(groupIDs: [UUID]) {
        guard let trackDragPayload, let view = reorderCoordinateView, let window = view.window else { return }
        let session = window.libraryTrackDragSession
        let id = session.beginSourceDrag(
            from: view,
            payload: trackDragPayload(groupIDs),
            content: windowDragContent,
            frame: windowDragFrame,
            motion: LibraryTrackDragMotion(
                control: dragReorderAnimation,
                settle: dragSettleAnimation(),
                settleDuration: motionPolicy.visualCompletionDelay(for: motionTokens[.gestureSettle])
            ),
            handlers: LibraryTrackDragWindowSession.SourceHandlers(
                returnHome: {
                    isAwaitingDrop = false
                    cancelDrag()
                },
                detach: { _ in
                    // The window carries the cards into the target; the rows
                    // were never moved, so they simply come back.
                    dragOverlayID = nil
                    clearDragState(keepVisualOrder: false)
                    onClearSelection()
                }
            )
        )
        dragOverlayID = id
        dragWindowSession = id == nil ? nil : session
    }

    @discardableResult
    private func publishFloatingDrag(animation: Animation? = nil) -> Bool {
        guard let dragOverlayID, let view = reorderCoordinateView else { return false }
        return dragWindowSession?.updateSourceDrag(
            dragOverlayID,
            from: view,
            frame: windowDragFrame,
            animation: animation
        ) ?? false
    }

    /// The list's scroll viewport, including its side padding.
    private var isPointerWithinList: Bool {
        guard let view = reorderCoordinateView, let window = view.window else { return true }
        guard window.frame.contains(NSEvent.mouseLocation) else { return false }
        guard let scrollView = enclosingScrollView, let documentView = scrollView.documentView,
              let pointer = currentMouseLocationInReorderSpace() else { return true }
        let viewport = view.convert(scrollView.contentView.documentVisibleRect, from: documentView).standardized
        return viewport.contains(pointer)
    }

    // MARK: - Targets and auto-scroll

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

        let pointerY = currentMouseLocationInReorderSpace()?.y ?? centerY
        let topReferenceY = min(pointerY, dragFloatingY)
        let bottomReferenceY = max(pointerY, dragFloatingY + dragGroupHeight)

        let topDistance = topReferenceY - viewport.minY
        let topRatio: CGFloat
        if topDistance < autoScrollEdgeThreshold {
            topRatio = max(0, (autoScrollEdgeThreshold - topDistance) / autoScrollEdgeThreshold)
        } else {
            topRatio = 0
        }

        let bottomDistance = viewport.maxY - bottomReferenceY
        let bottomRatio: CGFloat
        if bottomDistance < autoScrollBottomEdgeThreshold {
            bottomRatio = max(0, (autoScrollBottomEdgeThreshold - bottomDistance) / autoScrollBottomEdgeThreshold)
        } else {
            bottomRatio = 0
        }

        if canScrollUp, topRatio > bottomRatio, topRatio > 0 {
            return -scaledAutoScrollVelocity(for: topRatio)
        }
        if canScrollDown, bottomRatio > 0 {
            return scaledAutoScrollVelocity(for: bottomRatio)
        }
        return 0
    }

    private func scaledAutoScrollVelocity(for ratio: CGFloat) -> CGFloat {
        guard ratio > 0 else { return 0 }
        if ratio <= 1.0 {
            let eased = pow(Double(ratio), 1.7)
            return autoScrollMinVelocity
                + (autoScrollMaxVelocity - autoScrollMinVelocity) * CGFloat(eased)
        } else {
            let extra = min(1.0, (ratio - 1.0) / 0.6)
            let extraEased = pow(Double(extra), 1.3)
            return autoScrollMaxVelocity
                + (autoScrollOverdriveMaxVelocity - autoScrollMaxVelocity) * CGFloat(extraEased)
        }
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
        guard draggingID != nil, !isDragOutsideList, abs(autoScrollVelocity) > 0.5 else {
            stopAutoScroll()
            return
        }

        let delta = scrollEnclosingScrollView(by: autoScrollVelocity / 60)
        guard abs(delta) > 0.05 else {
            stopAutoScroll()
            return
        }

        if let mouse = currentMouseLocationInReorderSpace() {
            dragFloatingY = mouse.y - dragPointerYOffset
            if dragOverlayID != nil {
                dragFloatingX = mouse.x - dragPointerXOffset
            }
        }
        let centerY = dragFloatingY + dragGroupHeight / 2
        updateDragTarget(forCenterY: centerY)
        updateAutoScroll(forCenterY: centerY)
        publishFloatingDrag()
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
        let pointerY = currentMouseLocationInReorderSpace()?.y ?? value.location.y
        return pointerY - dragPointerYOffset
    }

    private func floatingLeadingX(for value: DragGesture.Value) -> CGFloat {
        let pointerX = currentMouseLocationInReorderSpace()?.x ?? value.location.x
        return pointerX - dragPointerXOffset
    }

    private func currentMouseLocationInReorderSpace() -> CGPoint? {
        guard
            let coordinateView = reorderCoordinateView,
            let window = coordinateView.window
        else { return nil }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return coordinateView.convert(windowPoint, from: nil)
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

private struct ReorderableFloatingCard: Identifiable {
    let id: UUID
    let content: AnyView
    let height: CGFloat
    let pileX: CGFloat
    let pileY: CGFloat
    let pileRotation: Double
    let depth: Int
}

/// Shared by the source and its window-hosted renderer. Card content and IDs
/// stay mounted for the entire drag; only these numeric poses change.
@Observable
private final class ReorderableFloatingCardsPresentation {
    struct Pose: Equatable {
        let offsets: [UUID: CGFloat]
        let pileProgress: CGFloat
        let glassOpacity: Double
        let isFinishing: Bool
    }

    let cards: [ReorderableFloatingCard]
    var offsets: [UUID: CGFloat]
    var pileProgress: CGFloat = 0
    var glassOpacity: Double = 0
    var isFinishing = false
    var hasMounted = false
    var animation: Animation?

    init(cards: [ReorderableFloatingCard] = [], offsets: [UUID: CGFloat] = [:]) {
        self.cards = cards
        self.offsets = offsets
    }

    var pose: Pose {
        Pose(
            offsets: offsets,
            pileProgress: pileProgress,
            glassOpacity: glassOpacity,
            isFinishing: isFinishing
        )
    }
}

private struct ReorderableFloatingCards: View {
    let presentation: ReorderableFloatingCardsPresentation
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let backgroundColor: Color
    let accentColor: Color
    let badge: String
    let maxVisibleCards: Int
    let onMount: () -> Void

    var body: some View {
        let pose = presentation.pose
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .topLeading) {
                ForEach(presentation.cards) { card in
                    card.content
                        .frame(width: width, height: card.height, alignment: .topLeading)
                        .modifier(LibraryTrackDragCardSurface(
                            cornerRadius: cornerRadius,
                            backgroundColor: backgroundColor,
                            glassOpacity: pose.glassOpacity
                        ))
                        .rotationEffect(.degrees(card.pileRotation * Double(pose.pileProgress)))
                        .offset(
                            x: card.pileX * pose.pileProgress,
                            y: (pose.offsets[card.id] ?? 0) + card.pileY * pose.pileProgress
                        )
                        .opacity(card.depth < maxVisibleCards || pose.isFinishing ? 1 : 1 - Double(pose.pileProgress))
                        .zIndex(Double(presentation.cards.count - card.depth))
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            // UI exception: preserve the lifted reorder cards' existing shadow.
            .shadow(
                color: GlassStyleTokens.subtleShadowColor.opacity(pose.glassOpacity),
                radius: GlassStyleTokens.subtleShadowRadius + 5,
                x: 0,
                y: 5
            )

            if presentation.cards.count > 1 && !pose.isFinishing {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(accentColor))
                    .offset(x: 5, y: -6)
                    .transition(.opacity)
            }
        }
        // Resolve the animation in this host, independently of the source's
        // pointer updates, which deliberately have no animation transaction.
        .animation(presentation.animation, value: pose)
        .onAppear(perform: onMount)
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
