import MotionKit
import SwiftUI

struct SidebarSetBarSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionPolicy) private var configuredMotionPolicy
    @Environment(\.motionTokens) private var motionTokens
    @Namespace private var editorSpace
    @State private var frames: [SidebarSetBarEditorRegion: CGRect] = [:]
    @State private var drag: ItemDrag?
    @State private var paletteRows = SidebarSetBarPalette.initialRows
    @State private var hoveredSeparatorID: UUID?
    @State private var floatingPosition = CGPoint.zero

    private enum Destination: Equatable {
        case preview(Int)
        case palette
        case origin
    }

    private enum DragPhase: Equatable {
        case lifting
        case dragging
        case awaitingLayout
        case settling
        case fading
    }

    private struct ItemDrag {
        var token = UUID()
        var item: SidebarSetBarItem
        var isExisting: Bool
        var original: SidebarSetBarConfiguration
        var originalFrames: [SidebarSetBarEditorRegion: CGRect]
        var grabOffset: CGSize
        var pointerPosition: CGPoint
        var liftStartPosition: CGPoint
        var liftProgress: CGFloat = 0
        var destination: Destination = .origin
        var paletteDropPosition: PaletteDropPosition?
        var phase: DragPhase
        var releaseRequested = false
        var releaseVelocity = CGSize.zero
    }

    private struct PaletteDropPosition: Equatable {
        var row: Int
        var index: Int
    }

    private var configuration: SidebarSetBarConfiguration { settings.sidebarSetBarConfiguration }
    private var motionPolicy: MotionPolicy {
        configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
    }

    private var displayConfiguration: SidebarSetBarConfiguration {
        guard let drag else { return configuration }
        return proposal(for: drag, destination: drag.destination)
    }

    private var reservedPaletteKind: SidebarSetBarItemKind? {
        guard let drag, !drag.isExisting,
              case .preview = drag.destination
        else { return nil }
        return drag.item.kind
    }

    private var displayPaletteRows: [[SidebarSetBarItemKind]] {
        var available = Set(displayConfiguration.availableKinds)
        if let reservedPaletteKind { available.insert(reservedPaletteKind) }
        var rows = paletteRows.map { $0.filter(available.contains) }
        if let drag, drag.isExisting, drag.destination == .palette,
           let position = drag.paletteDropPosition {
            for row in rows.indices {
                rows[row].removeAll { $0 == drag.item.kind }
            }
            let row = min(max(position.row, 0), rows.count - 1)
            let index = min(max(position.index, 0), rows[row].count)
            rows[row].insert(drag.item.kind, at: index)
        }
        return rows
    }

    private var paletteKinds: [SidebarSetBarItemKind] {
        displayPaletteRows.flatMap { $0 }
    }

    private var returningPaletteKind: SidebarSetBarItemKind? {
        guard let drag, drag.isExisting, drag.destination == .palette else { return nil }
        return drag.item.kind
    }

    private var pendingCandidate: SidebarSetBarItemKind? {
        guard let drag else { return nil }
        switch drag.destination {
        case .palette: return drag.item.kind
        case .origin: return drag.isExisting ? nil : drag.item.kind
        case .preview: return nil
        }
    }

    private var paletteScrollTarget: SidebarSetBarItemKind? {
        guard drag?.phase == .awaitingLayout, let kind = pendingCandidate else { return nil }
        guard let frame = frames[.candidateCard(kind)], let viewport = frames[.palette] else { return kind }
        return frame.minX >= viewport.minX && frame.maxX <= viewport.maxX ? nil : kind
    }

    private func shouldMorphSeparator(for drag: ItemDrag) -> Bool {
        guard case .preview = drag.destination else { return false }
        return drag.item.kind == .separator
    }

    var body: some View {
        SettingsSection("侧边栏按钮", headerTrailing: {
            Button("恢复默认") { settings.sidebarSetBarConfiguration = .defaultValue }
                .buttonStyle(AppPanelButtonStyle())
                .disabled(drag != nil)
        }) {
            VStack(spacing: 12) {
                preview
                SidebarSetBarPalette(
                    rows: displayPaletteRows,
                    buttonCount: displayConfiguration.buttonCount,
                    pendingKind: pendingCandidate,
                    reservedKind: reservedPaletteKind,
                    returningKind: returningPaletteKind,
                    scrollTarget: paletteScrollTarget,
                    coordinateSpace: editorSpace,
                    onAdd: add
                )
            }
            .coordinateSpace(name: editorSpace)
            .background {
                Color.clear.preference(key: SidebarSetBarEditorFrames.self, value: [
                    .layout(displayConfiguration.items.map(\.id)): .zero,
                ])
            }
            .onPreferenceChange(SidebarSetBarEditorFrames.self) { value in
                frames = value
                landIfReady(using: value)
            }
            .overlay {
                SidebarSetBarPointerSurface(
                    regions: pointerRegions,
                    isEnabled: drag == nil || drag?.phase == .dragging,
                    onClick: click,
                    onBegin: beginDrag,
                    onMove: moveDrag,
                    onRelease: releaseDrag,
                    onCancel: cancelDrag
                )
            }
            .overlay(alignment: .topLeading) {
                if let drag {
                    dragGhost(for: drag)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            // Opening settings stays static. Only an active arrangement may animate.
            .transaction { transaction in
                if drag == nil { transaction.animation = nil }
            }
            .task(id: drag?.phase == .awaitingLayout) { @MainActor in
                await Task.yield()
                landIfReady(using: frames)
            }
            .task(id: drag?.phase == .lifting) { @MainActor in
                guard let drag, drag.phase == .lifting else { return }
                let token = drag.token
                await Task.yield()
                guard self.drag?.token == token, self.drag?.phase == .lifting else { return }
                animateCandidateLift(token: token)
            }
            .onDisappear { drag = nil }
        }
    }

    private var preview: some View {
        ZStack {
            HStack(spacing: 10) {
                previewHint("从下方拖入以添加")

                ZStack {
                    if displayConfiguration.items.isEmpty {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(themeStore.appForegroundPalette.secondaryColor.opacity(0.4))
                            .frame(width: GlassStyleTokens.headerControlHeight, height: GlassStyleTokens.headerControlHeight)
                    }
                    SidebarSetBar(configuration: displayConfiguration) { item in
                        previewItem(item)
                    } separator: { item in
                        previewItem(item)
                    }
                    .motionAnimation(.layout, value: displayConfiguration.items.map(\.id))
                }
                .fixedSize(horizontal: true, vertical: false)

                previewHint("拖至下方以移除")
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 84)
        .background(
            themeStore.appForegroundPalette.secondaryColor.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .sidebarSetBarFrame(.preview, in: editorSpace)
    }

    private func previewHint(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(themeStore.appForegroundPalette.secondaryColor.opacity(0.72))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .allowsHitTesting(false)
    }

    private func previewItem(_ item: SidebarSetBarItem) -> some View {
        Group {
            if item.kind == .separator {
                Color.clear
                    .frame(width: SidebarSetBarMetrics.separatorWidth, height: GlassStyleTokens.headerControlHeight)
                    .help("分割线")
                    .accessibilityLabel("分割线")
                    .accessibilityAction(named: Text("移除")) { remove(item) }
            } else {
                SidebarSetBarButton(kind: item.kind, isSegment: true) { remove(item) }
                    .opacity(drag?.item.id == item.id ? 0 : 1)
            }
        }
        .overlay {
            if drag?.item.id == item.id {
                Group {
                    if item.kind == .separator {
                        SidebarSetBarSeparatorDropTarget(tint: themeStore.accentColor)
                    } else {
                        SidebarSetBarDropTarget(tint: themeStore.accentColor)
                    }
                }
                .opacity(drag?.phase == .fading ? 0 : 1)
            } else if item.kind == .separator, hoveredSeparatorID == item.id {
                SidebarSetBarSeparatorDropTarget(tint: themeStore.accentColor)
                    .transition(.opacity)
            }
        }
        .onHover { hovering in
            guard item.kind == .separator else { return }
            hoveredSeparatorID = hovering ? item.id : nil
        }
        .motionAnimation(.microInteraction, value: hoveredSeparatorID == item.id)
        .sidebarSetBarFrame(.item(item.id), in: editorSpace)
    }

    private var pointerRegions: [SidebarSetBarEditorRegion: CGRect] {
        var result: [SidebarSetBarEditorRegion: CGRect] = [:]
        for item in displayConfiguration.items {
            if let rect = frames[.item(item.id)] { result[.item(item.id)] = rect }
        }
        guard let viewport = frames[.palette] else { return result }
        for kind in displayConfiguration.availableKinds {
            let isEnabled = kind == .separator
                ? displayConfiguration.buttonCount >= 2
                : displayConfiguration.buttonCount < SidebarSetBarConfiguration.maximumButtonCount
            if isEnabled, let rect = frames[.candidateCard(kind)] {
                let visible = rect.intersection(viewport)
                if !visible.isNull { result[.candidateCard(kind)] = visible }
            }
        }
        return result
    }

    private func click(_ region: SidebarSetBarEditorRegion) {
        guard drag == nil else { return }
        switch region {
        case .item(let id):
            settings.sidebarSetBarConfiguration = configuration.removing(id)
        case .candidateCard(let kind): add(kind)
        case .candidate: break
        default: break
        }
    }

    private func beginDrag(_ region: SidebarSetBarEditorRegion, at point: CGPoint) {
        guard drag == nil else { return }
        let item: SidebarSetBarItem
        let isExisting: Bool
        let sourceRegion: SidebarSetBarEditorRegion
        let liftsFromCandidate: Bool
        switch region {
        case .item(let id):
            guard let existing = configuration.items.first(where: { $0.id == id }) else { return }
            item = existing
            isExisting = true
            sourceRegion = .item(id)
            liftsFromCandidate = false
        case .candidateCard(let kind):
            item = SidebarSetBarItem(kind: kind)
            isExisting = false
            sourceRegion = .candidate(kind)
            liftsFromCandidate = true
        default: return
        }
        guard let source = frames[sourceRegion] else { return }
        let center = CGPoint(x: source.midX, y: source.midY)
        drag = ItemDrag(
            item: item, isExisting: isExisting, original: configuration, originalFrames: frames,
            grabOffset: liftsFromCandidate
                ? .zero
                : CGSize(width: point.x - center.x, height: point.y - center.y),
            pointerPosition: point,
            liftStartPosition: center,
            phase: liftsFromCandidate ? .lifting : .dragging
        )
        floatingPosition = center
    }

    private func moveDrag(to point: CGPoint) {
        guard let drag, drag.phase == .dragging || drag.phase == .lifting else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.drag?.pointerPosition = point
            if drag.phase == .dragging {
                floatingPosition = CGPoint(
                    x: point.x - drag.grabOffset.width,
                    y: point.y - drag.grabOffset.height
                )
            }
        }
        let target = destination(at: point, for: drag)
        let dropPosition = drag.isExisting && target == .palette
            ? paletteDropPosition(at: point, for: drag.item.kind)
            : nil
        guard target != drag.destination || dropPosition != drag.paletteDropPosition else { return }
        withAnimation(motionPolicy.animation(for: motionTokens[.layout])) {
            self.drag?.destination = target
            self.drag?.paletteDropPosition = dropPosition
        }
    }

    private func paletteDropPosition(
        at point: CGPoint,
        for kind: SidebarSetBarItemKind
    ) -> PaletteDropPosition? {
        guard let viewport = frames[.palette], viewport.contains(point) else { return nil }
        let peersByRow = displayPaletteRows.map { $0.filter { $0 != kind } }
        guard !peersByRow.isEmpty else { return nil }

        var targetRow = 0
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for row in peersByRow.indices {
            let centers = peersByRow[row].compactMap { frames[.candidateCard($0)]?.midY }
            let fallbackY = viewport.minY + (row == 0 ? 30 : 90)
            let centerY = centers.isEmpty
                ? fallbackY
                : centers.reduce(0, +) / CGFloat(centers.count)
            let distance = abs(point.y - centerY)
            if distance < nearestDistance {
                nearestDistance = distance
                targetRow = row
            }
        }

        let peers = peersByRow[targetRow]
        let index = peers.firstIndex { peer in
            guard let frame = frames[.candidateCard(peer)] else { return false }
            return point.x < frame.midX
        } ?? peers.count
        return PaletteDropPosition(row: targetRow, index: index)
    }

    private func animateCandidateLift(token: UUID) {
        guard let animation = motionPolicy.animation(for: motionTokens[.gestureSettle]) else {
            finishCandidateLift(token: token)
            return
        }
        withAnimation(animation, completionCriteria: .removed) {
            guard self.drag?.token == token else { return }
            self.drag?.liftProgress = 1
        } completion: {
            self.finishCandidateLift(token: token)
        }
    }

    private func finishCandidateLift(token: UUID) {
        guard let drag, drag.token == token, drag.phase == .lifting else { return }
        let landedPosition = CGPoint(
            x: drag.pointerPosition.x - drag.grabOffset.width,
            y: drag.pointerPosition.y - drag.grabOffset.height
        )
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            floatingPosition = landedPosition
            self.drag?.phase = drag.releaseRequested ? .awaitingLayout : .dragging
        }
        if drag.releaseRequested {
            landIfReady(using: frames)
        }
    }

    @ViewBuilder
    private func dragGhost(for drag: ItemDrag) -> some View {
        if drag.phase == .lifting {
            SidebarSetBarDragGhost(
                kind: drag.item.kind,
                morphsSeparator: shouldMorphSeparator(for: drag),
                isFading: false
            )
            .frame(width: GlassStyleTokens.headerControlHeight, height: GlassStyleTokens.headerControlHeight)
            .modifier(
                SidebarSetBarBezierFlightEffect(
                    start: drag.liftStartPosition,
                    destination: drag.pointerPosition,
                    progress: drag.liftProgress
                )
            )
        } else {
            SidebarSetBarDragGhost(
                kind: drag.item.kind,
                morphsSeparator: shouldMorphSeparator(for: drag),
                isFading: drag.phase == .fading
            )
            .position(floatingPosition)
        }
    }

    private func destination(at point: CGPoint, for drag: ItemDrag) -> Destination {
        if frames[.preview]?.contains(point) == true {
            // Frozen launch geometry avoids oscillation as the centered preview makes room.
            let index = drag.original.items.firstIndex { item in
                guard let rect = drag.originalFrames[.item(item.id)] else { return false }
                return point.x < rect.midX
            } ?? drag.original.items.count
            let target = Destination.preview(index)
            if proposal(for: drag, destination: target).items.contains(where: { $0.id == drag.item.id }) {
                return target
            }
        } else if frames[.palette]?.contains(point) == true {
            return .palette
        }
        return .origin
    }

    private func proposal(for drag: ItemDrag, destination: Destination) -> SidebarSetBarConfiguration {
        switch destination {
        case .preview(let index):
            return drag.isExisting
                ? drag.original.moving(drag.item.id, to: index)
                : drag.original.inserting(drag.item, at: index)
        case .palette:
            return drag.isExisting ? drag.original.removing(drag.item.id) : drag.original
        case .origin: return drag.original
        }
    }

    private func releaseDrag(at point: CGPoint, velocity: CGSize) {
        moveDrag(to: point)
        guard let drag else { return }
        settings.sidebarSetBarConfiguration = proposal(for: drag, destination: drag.destination)
        if drag.phase == .lifting {
            self.drag?.releaseVelocity = velocity
            self.drag?.releaseRequested = true
        } else {
            self.drag?.releaseVelocity = velocity
            self.drag?.phase = .awaitingLayout
        }
    }

    private func cancelDrag() {
        guard drag != nil else { return }
        drag?.destination = .origin
        drag?.paletteDropPosition = nil
        drag?.releaseVelocity = .zero
        if drag?.phase == .lifting {
            drag?.releaseRequested = true
        } else {
            drag?.phase = .awaitingLayout
        }
    }

    private func landIfReady(using frames: [SidebarSetBarEditorRegion: CGRect]) {
        guard let drag, drag.phase == .awaitingLayout else { return }
        guard frames[.layout(displayConfiguration.items.map(\.id))] != nil else { return }
        let region: SidebarSetBarEditorRegion
        switch drag.destination {
        case .preview: region = .item(drag.item.id)
        case .palette: region = .candidate(drag.item.kind)
        case .origin: region = drag.isExisting ? .item(drag.item.id) : .candidate(drag.item.kind)
        }
        guard let frame = frames[region] else { return }
        if case .candidate = region, let viewport = frames[.palette] {
            guard let card = frames[.candidateCard(drag.item.kind)],
                  card.minX >= viewport.minX, card.maxX <= viewport.maxX else { return }
        }
        let target = CGPoint(x: frame.midX, y: frame.midY)
        let dx = target.x - floatingPosition.x
        let dy = target.y - floatingPosition.y
        let distanceSquared = dx * dx + dy * dy
        let velocity = distanceSquared > 1
            ? (drag.releaseVelocity.width * dx + drag.releaseVelocity.height * dy) / distanceSquared : 0
        let initialVelocity = MotionSpec.clampedInitialVelocity(Double(velocity))
        withAnimation(
            motionPolicy.animation(for: motionTokens[.gestureSettle], initialVelocity: initialVelocity),
            completionCriteria: .removed
        ) {
            self.drag?.phase = .settling
            floatingPosition = target
        } completion: {
            guard self.drag?.token == drag.token else { return }
            guard case .preview = drag.destination else {
                if drag.destination == .palette { self.commitPalettePlacement(for: drag) }
                self.drag = nil
                return
            }
            withAnimation(
                motionPolicy.animation(for: motionTokens[.microInteraction]),
                completionCriteria: .removed
            ) {
                self.drag?.phase = .fading
            } completion: {
                guard self.drag?.token == drag.token else { return }
                self.hoveredSeparatorID = nil
                self.drag = nil
            }
        }
    }

    private func commitPalettePlacement(for drag: ItemDrag) {
        guard let position = drag.paletteDropPosition,
              !paletteRows.isEmpty else { return }
        let kind = drag.item.kind
        var updatedRows = paletteRows.map { $0.filter { $0 != kind } }
        let row = min(max(position.row, 0), updatedRows.count - 1)
        let visiblePeers = displayPaletteRows[row].filter { $0 != kind }

        let insertionIndex: Int
        if position.index < visiblePeers.count,
           let nextIndex = updatedRows[row].firstIndex(of: visiblePeers[position.index]) {
            insertionIndex = nextIndex
        } else if let previousKind = visiblePeers.last,
                  let previousIndex = updatedRows[row].firstIndex(of: previousKind) {
            insertionIndex = previousIndex + 1
        } else {
            insertionIndex = updatedRows[row].count
        }
        updatedRows[row].insert(kind, at: min(max(insertionIndex, 0), updatedRows[row].count))
        paletteRows = updatedRows
    }

    private func add(_ kind: SidebarSetBarItemKind) {
        guard drag == nil else { return }
        let index = kind == .separator ? max(0, configuration.items.count - 1) : configuration.items.count
        settings.sidebarSetBarConfiguration = configuration.inserting(SidebarSetBarItem(kind: kind), at: index)
    }

    private func remove(_ item: SidebarSetBarItem) {
        guard drag == nil else { return }
        settings.sidebarSetBarConfiguration = configuration.removing(item.id)
    }
}

@MainActor
private struct SidebarSetBarDragGhost: View {
    let kind: SidebarSetBarItemKind
    let morphsSeparator: Bool
    let isFading: Bool

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if kind == .separator {
                Rectangle()
                    .fill(themeStore.accentColor)
                    .frame(width: 1.5, height: 14)
                    .frame(
                        width: morphsSeparator ? SidebarSetBarMetrics.separatorWidth : GlassStyleTokens.headerControlHeight,
                        height: GlassStyleTokens.headerControlHeight
                    )
                    .liquidGlassPill(colorScheme: colorScheme)
                    .opacity(isFading ? 0 : 1)
            } else {
                SidebarSetBarButton(kind: kind, action: {})
            }
        }
        .frame(height: GlassStyleTokens.headerControlHeight)
    }
}

private struct SidebarSetBarBezierFlightEffect: GeometryEffect {
    let start: CGPoint
    let destination: CGPoint
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let point = pointOnCurve(at: min(max(progress, 0), 1))
        return ProjectionTransform(
            CGAffineTransform(
                translationX: point.x - size.width / 2,
                y: point.y - size.height / 2
            )
        )
    }

    private func pointOnCurve(at progress: CGFloat) -> CGPoint {
        let deltaX = destination.x - start.x
        let deltaY = destination.y - start.y
        let distance = hypot(deltaX, deltaY)
        guard distance > 1 else { return start }

        let bend = min(26, distance * 0.16)
        let direction: CGFloat = deltaY <= 0 ? 1 : -1
        let perpendicularX = -deltaY / distance * bend * direction
        let perpendicularY = deltaX / distance * bend * direction
        let control1 = CGPoint(
            x: start.x + deltaX * 0.30 + perpendicularX,
            y: start.y + deltaY * 0.30 + perpendicularY
        )
        let control2 = CGPoint(
            x: start.x + deltaX * 0.70 + perpendicularX,
            y: start.y + deltaY * 0.70 + perpendicularY
        )
        let inverse = 1 - progress
        let inverseSquared = inverse * inverse
        let progressSquared = progress * progress
        return CGPoint(
            x: inverseSquared * inverse * start.x
                + 3 * inverseSquared * progress * control1.x
                + 3 * inverse * progressSquared * control2.x
                + progressSquared * progress * destination.x,
            y: inverseSquared * inverse * start.y
                + 3 * inverseSquared * progress * control1.y
                + 3 * inverse * progressSquared * control2.y
                + progressSquared * progress * destination.y
        )
    }
}
