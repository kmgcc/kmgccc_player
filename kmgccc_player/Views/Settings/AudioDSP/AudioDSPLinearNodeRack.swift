//
//  AudioDSPLinearNodeRack.swift
//  myPlayer2
//
//  Linear Node Rack for audio DSP effect chain.
//  Expresses processing order via a continuous vertical signal bus. Bypassed
//  nodes are routed around on an outer lane; a run of adjacent bypassed nodes
//  shares one detour that rejoins the bus at the next active node.
//
//  While a node is dragged its wire collapses into its terminal, the wires of
//  its neighbours retract into their own connection points, and everything
//  reconnects once the node settles into its new slot.
//

import MotionKit
import SwiftUI

struct AudioDSPLinearNodeRack: View {
    @Binding var nodes: [DSPNodeConfiguration]
    let format: DSPAudioFormat?
    let headroomDB: Double?
    @Binding var expandedNodeIDs: Set<UUID>
    @Binding var inputTrimDB: Double
    @Binding var outputTrimDB: Double
    @Binding var headroomMode: DSPHeadroomMode
    @Binding var headroomMarginDB: Double

    let onCommit: () -> Void
    let onRemoveNode: (UUID) -> Void
    let onUpdateNode: (UUID, (inout DSPNodeConfiguration) -> Void) -> Void

    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy

    // Reordering is a local preview until release; PCM work never follows
    // individual pointer events.
    @State private var draggingNodeID: UUID?
    @State private var dragNodeOrder: [UUID]?
    @State private var dragOrigin: CGPoint = .zero
    @State private var dragRowFrames: [UUID: CGRect] = [:]
    @State private var dragFloatingX: CGFloat = 0
    @State private var dragFloatingY: CGFloat = 0
    @State private var isLifted = false
    @State private var isFinishingDrag = false
    @State private var dragCleanupTask: Task<Void, Never>?
    @State private var rowGeometry = DSPRackGeometryCache()

    private let rackSpace = "dspLinearNodeRackCoordinateSpace"
    private let nodeHeaderHeight: CGFloat = DSPRackMetrics.nodeHeaderHeight
    private let nodeSpacing: CGFloat = 10
    private let dragHorizontalDamping: CGFloat = 0.4
    private let dragHorizontalLimit: CGFloat = 24
    private let liftedScale: CGFloat = 1.015

    private var palette: DSPRackPalette {
        DSPRackPalette(themeStore: themeStore, colorScheme: colorScheme)
    }

    private var rackNodes: [DSPNodeConfiguration] {
        guard let order = dragNodeOrder else { return nodes }
        let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.nodeID, $0) })
        return order.compactMap { nodesByID[$0] }
    }

    private var motionPolicy: MotionPolicy {
        configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
    }

    private var reorderAnimation: Animation? {
        motionPolicy.animation(for: motionTokens[.control])
    }

    private func settleAnimation(initialVelocity: Double = 0) -> Animation? {
        motionPolicy.animation(
            for: motionTokens[.gestureSettle],
            initialVelocity: initialVelocity
        )
    }

    var body: some View {
        let palette = self.palette
        let ordered = rackNodes
        let slotIndex = draggingNodeID.flatMap { id in ordered.firstIndex { $0.nodeID == id } }

        VStack(alignment: .leading, spacing: 0) {
            inputEndpointView(palette: palette)
            BusWireSegment(anchor: .top, isConnected: slotIndex != 0, color: palette.wire)
                .frame(height: 14)
            nodesRackList(ordered: ordered, palette: palette)
                .coordinateSpace(name: rackSpace)
            BusWireSegment(
                anchor: .bottom,
                isConnected: slotIndex == nil || slotIndex != ordered.count - 1,
                color: palette.wire
            )
            .frame(height: 14)
            outputEndpointView(palette: palette)
        }
        .onDisappear(perform: cancelDrag)
        .onChange(of: nodes.map(\.nodeID)) { _, _ in
            if !isFinishingDrag { cancelDrag() }
            rowGeometry.frames = rowGeometry.frames.filter { id, _ in nodes.contains { $0.nodeID == id } }
        }
    }

    // MARK: - Endpoints

    private func inputEndpointView(palette: DSPRackPalette) -> some View {
        endpointCard(title: "输入", systemImage: "waveform", trailing: nil, palette: palette) {
            DSPRangeSliderRow(
                title: "输入增益",
                value: $inputTrimDB,
                range: -24...24,
                step: 0.1,
                onCommit: onCommit
            )
        }
    }

    private func outputEndpointView(palette: DSPRackPalette) -> some View {
        endpointCard(
            title: "输出",
            systemImage: "speaker.wave.2",
            trailing: headroomDB.map {
                "预估余量 \($0.formatted(.number.precision(.fractionLength(1)))) dB"
            },
            palette: palette
        ) {
            DSPRangeSliderRow(
                title: "输出增益",
                value: $outputTrimDB,
                range: -24...24,
                step: 0.1,
                onCommit: onCommit
            )

            CapsulePicker(
                label: "余量保护",
                options: DSPHeadroomMode.allCases,
                selection: $headroomMode,
                displayName: { $0 == .automatic ? "自动" : "关闭" }
            )

            if headroomMode == .automatic {
                DSPRangeSliderRow(
                    title: "安全边距",
                    value: $headroomMarginDB,
                    range: 0...12,
                    step: 0.1,
                    onCommit: onCommit
                )
            }
        }
    }

    private func endpointCard<Content: View>(
        title: String,
        systemImage: String,
        trailing: String?,
        palette: DSPRackPalette,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(themeStore.accentColor)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.endpointSurface)
        )
    }

    // MARK: - Nodes Rack List

    @ViewBuilder
    private func nodesRackList(ordered: [DSPNodeConfiguration], palette: DSPRackPalette) -> some View {
        if nodes.isEmpty {
            emptyRackPlaceholder(palette: palette)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(ordered.enumerated()), id: \.element.nodeID) { index, node in
                    nodeRackRow(node: node, index: index, ordered: ordered, palette: palette)
                }
            }
            .overlay(alignment: .top) {
                if let draggingID = draggingNodeID,
                   let draggingNode = nodes.first(where: { $0.nodeID == draggingID }) {
                    let dragIndex = ordered.firstIndex(where: { $0.nodeID == draggingID }) ?? 0
                    floatingNodeCard(node: draggingNode, index: dragIndex, palette: palette)
                        .scaleEffect(isLifted ? liftedScale : 1, anchor: .leading)
                        // Applied inside the pointer-follow override below, so
                        // lifting and landing keep their own motion.
                        .motionAnimation(.control, value: isLifted)
                        .offset(x: dragFloatingX, y: dragFloatingY)
                        .transaction { transaction in
                            // Direct manipulation follows the pointer. Only
                            // release participates in the gesture-settle motion.
                            if !isFinishingDrag { transaction.animation = nil }
                        }
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func emptyRackPlaceholder(palette: DSPRackPalette) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("尚未添加效果")
                .font(.system(size: 13, weight: .medium))
            Text("信号原样通过。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.bypassedNodeSurface)
        )
        .padding(.leading, DSPRackMetrics.gutterWidth)
        .background(alignment: .leading) {
            BusWireSegment(anchor: .top, isConnected: true, color: palette.wire)
                .frame(width: DSPRackMetrics.gutterWidth)
        }
    }

    // MARK: - Node Rack Row

    private func nodeRackRow(
        node: DSPNodeConfiguration,
        index: Int,
        ordered: [DSPNodeConfiguration],
        palette: DSPRackPalette
    ) -> some View {
        let isDragging = draggingNodeID == node.nodeID
        let isExpanded = expandedNodeIDs.contains(node.nodeID)
        let isLast = index == ordered.count - 1

        return nodeCardContent(node: node, index: index, isExpanded: isExpanded, palette: palette)
            .opacity(isDragging ? 0 : 1)
            .padding(.leading, DSPRackMetrics.gutterWidth)
            // Each row owns the following gap, so its wire stays inside its
            // drawing bounds and meets the next row without clipped extensions.
            .padding(.bottom, isLast ? 0 : nodeSpacing)
            .background(alignment: .leading) {
                NodeWireGutter(
                    routing: routing(for: index, in: ordered),
                    headerHeight: nodeHeaderHeight,
                    wireColor: palette.wire,
                    terminalColor: themeStore.accentColor,
                    bypassedTerminalColor: palette.wire
                )
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(rackSpace))
            } action: { newFrame in
                // Cache measurements without invalidating the view tree. Dragging
                // reads a snapshot; later animation frames only seed the next drag.
                rowGeometry.frames[node.nodeID] = newFrame
            }
    }

    /// Wiring for one row. The dragged slot is detached from the chain, and
    /// its neighbours end at their own terminals instead of reaching across it.
    private func routing(for index: Int, in ordered: [DSPNodeConfiguration]) -> DSPWireRouting {
        let node = ordered[index]
        let isSlot = node.nodeID == draggingNodeID
        let previous = index > 0 ? ordered[index - 1] : nil
        let next = index + 1 < ordered.count ? ordered[index + 1] : nil
        let previousIsSlot = previous.map { $0.nodeID == draggingNodeID } ?? false
        let nextIsSlot = next.map { $0.nodeID == draggingNodeID } ?? false
        let connectsAbove = !isSlot && !previousIsSlot
        let connectsBelow = !isSlot && !nextIsSlot

        return DSPWireRouting(
            isBypassed: !node.enabled,
            joinsAbove: connectsAbove && !node.enabled && previous?.enabled == false,
            joinsBelow: connectsBelow && !node.enabled && next?.enabled == false,
            connectsAbove: connectsAbove,
            connectsBelow: connectsBelow,
            showsTerminal: !isSlot
        )
    }

    // MARK: - Node Card Content

    private func nodeCardContent(
        node: DSPNodeConfiguration,
        index: Int,
        isExpanded: Bool,
        palette: DSPRackPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            nodeHeader(node: node, index: index, isExpanded: isExpanded)

            if isExpanded {
                nodeDetailEditor(node: node)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(node.enabled ? palette.nodeSurface : palette.bypassedNodeSurface)
        )
    }

    /// Header shared by the rack row and the floating drag card, so lifting a
    /// node keeps every element in place.
    private func nodeHeader(node: DSPNodeConfiguration, index: Int, isExpanded: Bool) -> some View {
        let isBypassed = !node.enabled
        let title = DSPNodeDescriptor.title(for: node.typeID)

        return HStack(spacing: 10) {
            Button {
                toggleExpansion(node.nodeID)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)

                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isBypassed ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(themeStore.accentColor))
                        .frame(minWidth: 14)

                    Image(systemName: DSPNodeDescriptor.icon(for: node.typeID))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isBypassed ? .secondary : .primary)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isBypassed ? .secondary : .primary)
                        let summary = DSPNodeDescriptor.summary(for: node)
                        if !summary.isEmpty {
                            Text(summary)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "已展开" : "已收起")

            Toggle("", isOn: Binding(
                get: { node.enabled },
                set: { enabled in
                    guard enabled != node.enabled else { return }
                    onUpdateNode(node.nodeID) { $0.enabled = enabled }
                    onCommit()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityLabel("启用\(title)")

            Button {
                withAnimation(reorderAnimation) { onRemoveNode(node.nodeID) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("移除")
            .accessibilityLabel("移除\(title)")

            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: nodeHeaderHeight)
                .contentShape(Rectangle())
                .highPriorityGesture(reorderGesture(for: node.nodeID))
                .help("拖动排序")
                .accessibilityLabel("排序")
                .accessibilityAction(named: "上移") { moveNode(node.nodeID, by: -1) }
                .accessibilityAction(named: "下移") { moveNode(node.nodeID, by: 1) }
        }
        .frame(height: nodeHeaderHeight)
        .padding(.leading, 10)
        .padding(.trailing, 8)
    }

    private func toggleExpansion(_ nodeID: UUID) {
        withAnimation(reorderAnimation) {
            if expandedNodeIDs.contains(nodeID) {
                expandedNodeIDs.remove(nodeID)
            } else {
                expandedNodeIDs.insert(nodeID)
            }
        }
    }

    /// Keyboard and VoiceOver path for reordering; pointer users drag the handle.
    private func moveNode(_ nodeID: UUID, by offset: Int) {
        guard let index = nodes.firstIndex(where: { $0.nodeID == nodeID }) else { return }
        let destination = index + offset
        guard nodes.indices.contains(destination) else { return }
        var reordered = nodes
        reordered.swapAt(index, destination)
        withAnimation(reorderAnimation) { nodes = reordered }
    }

    // MARK: - Detailed Node Editors

    @ViewBuilder
    private func nodeDetailEditor(node: DSPNodeConfiguration) -> some View {
        switch node.typeID {
        case DSPNodeConfiguration.parametricEQTypeID:
            if let bands = node.parametricEQBands {
                AudioDSPEQEditor(
                    node: node,
                    bands: bands,
                    sampleRate: format?.sampleRate,
                    onBandChange: { bandIndex, band in
                        onUpdateNode(node.nodeID) { candidate in
                            guard var updated = candidate.parametricEQBands,
                                  updated.indices.contains(bandIndex) else { return }
                            updated[bandIndex] = band
                            candidate.parametricEQBands = updated
                        }
                    },
                    onCommit: onCommit
                )
                .equatable()
            } else {
                unreadableParameters
            }
        case DSPNodeConfiguration.equalLoudnessTypeID:
            if node.equalLoudnessParameters != nil {
                equalLoudnessEditor(node: node)
            } else {
                unreadableParameters
            }
        case DSPNodeConfiguration.stereoWidthTypeID,
             DSPNodeConfiguration.virtualBassTypeID,
             DSPNodeConfiguration.tubeTypeID:
            nativeEffectsEditor(node: node)
        case DSPNodeConfiguration.scriptTypeID:
            AudioDSPScriptNodeCard(
                node: node,
                format: scriptCompileFormat,
                dspController: appSession.audioDSPController,
                scriptController: appSession.audioDSPScriptController,
                onCommit: onCommit
            )
        default:
            unreadableParameters
        }
    }

    private var unreadableParameters: some View {
        Text("参数无法读取。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func equalLoudnessEditor(node: DSPNodeConfiguration) -> some View {
        let context = appSession.audioProcessingGlobalsController.equalLoudnessContext
        return VStack(alignment: .leading, spacing: 10) {
            AudioDSPEqualLoudnessResponseCurve(
                node: node,
                context: context,
                sampleRate: format?.sampleRate ?? 48_000,
                accentColor: themeStore.accentColor
            )
            .equatable()

            DSPRangeSliderRow(
                title: "强度",
                value: equalLoudnessBinding(for: node.nodeID, keyPath: \.strength),
                range: DSPEqualLoudnessParameters.strengthRange,
                step: 0.01,
                unit: "",
                fractionDigits: 2,
                onCommit: onCommit
            )

            DSPRangeSliderRow(
                title: "低频补偿",
                value: equalLoudnessBinding(for: node.nodeID, keyPath: \.maxBassGainDB),
                range: DSPEqualLoudnessParameters.maxBassGainRange,
                step: 0.1,
                onCommit: onCommit
            )

            DSPRangeSliderRow(
                title: "高频补偿",
                value: equalLoudnessBinding(for: node.nodeID, keyPath: \.maxTrebleGainDB),
                range: DSPEqualLoudnessParameters.maxTrebleGainRange,
                step: 0.1,
                onCommit: onCommit
            )
        }
    }

    @ViewBuilder
    private func nativeEffectsEditor(node: DSPNodeConfiguration) -> some View {
        let qualities = DSPNodeConfiguration.supportedQualities(forTypeID: node.typeID)

        VStack(alignment: .leading, spacing: 10) {
            if qualities.count > 1 {
                CapsulePicker(
                    label: "质量",
                    options: Array(qualities).sorted(by: DSPNodeDescriptor.qualityOrder),
                    selection: qualityBinding(for: node.nodeID),
                    displayName: DSPNodeDescriptor.qualityTitle
                )
            }

            switch node.typeID {
            case DSPNodeConfiguration.stereoWidthTypeID:
                DSPRangeSliderRow(
                    title: "宽度",
                    value: stereoWidthBinding(for: node.nodeID, keyPath: \.width),
                    range: DSPStereoWidthParameters.widthRange,
                    step: 0.01,
                    unit: "×",
                    fractionDigits: 2,
                    onCommit: onCommit
                )
                DSPRangeSliderRow(
                    title: "增益",
                    value: stereoWidthBinding(for: node.nodeID, keyPath: \.outputTrimDB),
                    range: DSPStereoWidthParameters.outputTrimRange,
                    step: 0.1,
                    onCommit: onCommit
                )
            case DSPNodeConfiguration.virtualBassTypeID:
                DSPRangeSliderRow(
                    title: "强度",
                    value: virtualBassBinding(for: node.nodeID, keyPath: \.amount),
                    range: DSPVirtualBassParameters.amountRange,
                    step: 0.01,
                    unit: "",
                    fractionDigits: 2,
                    onCommit: onCommit
                )
                DSPRangeSliderRow(
                    title: "混合",
                    value: virtualBassBinding(for: node.nodeID, keyPath: \.mix),
                    range: DSPVirtualBassParameters.mixRange,
                    step: 0.01,
                    unit: "",
                    fractionDigits: 2,
                    onCommit: onCommit
                )
            case DSPNodeConfiguration.tubeTypeID:
                DSPRangeSliderRow(
                    title: "驱动",
                    value: tubeBinding(for: node.nodeID, keyPath: \.driveDB),
                    range: DSPTubeParameters.driveRange,
                    step: 0.1,
                    onCommit: onCommit
                )
                DSPRangeSliderRow(
                    title: "混合",
                    value: tubeBinding(for: node.nodeID, keyPath: \.mix),
                    range: DSPTubeParameters.mixRange,
                    step: 0.01,
                    unit: "",
                    fractionDigits: 2,
                    onCommit: onCommit
                )
            default:
                EmptyView()
            }
        }
    }

    private var scriptCompileFormat: DSPAudioFormat {
        format ?? DSPAudioFormat(
            sampleRate: 48_000,
            channelCount: 2,
            rawLayoutData: nil,
            channelLabels: nil,
            layoutIsKnown: false
        )
    }

    // MARK: - Floating Drag Card

    private func floatingNodeCard(
        node: DSPNodeConfiguration,
        index: Int,
        palette: DSPRackPalette
    ) -> some View {
        nodeHeader(node: node, index: index, isExpanded: expandedNodeIDs.contains(node.nodeID))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(node.enabled ? palette.nodeSurface : palette.bypassedNodeSurface)
            )
            .padding(.leading, DSPRackMetrics.gutterWidth)
    }

    // MARK: - Reorder Gesture

    private func reorderGesture(for nodeID: UUID) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(rackSpace))
            .onChanged { gesture in
                guard !isFinishingDrag else { return }
                if draggingNodeID == nil {
                    guard let origin = rowGeometry.frames[nodeID]?.origin else { return }
                    dragCleanupTask?.cancel()
                    dragOrigin = origin
                    dragRowFrames = rowGeometry.frames
                    for node in nodes.dropLast() {
                        dragRowFrames[node.nodeID]?.size.height -= nodeSpacing
                    }
                    dragFloatingX = 0
                    dragFloatingY = origin.y
                    dragNodeOrder = nodes.map(\.nodeID)
                    draggingNodeID = nodeID
                    // The floating card first appears at rest, then lifts on
                    // the next turn so the change is animated.
                    Task { @MainActor in
                        if draggingNodeID == nodeID, !isFinishingDrag { isLifted = true }
                    }
                }
                guard draggingNodeID == nodeID, var order = dragNodeOrder else { return }

                // The launch position is captured once, before any rows move.
                // Snapshot thresholds also prevent animated layout feedback.
                dragFloatingY = dragOrigin.y + gesture.translation.height
                dragFloatingX = max(
                    -dragHorizontalLimit,
                    min(dragHorizontalLimit, gesture.translation.width * dragHorizontalDamping)
                )
                let centerY = dragFloatingY + nodeHeaderHeight / 2
                let target = nodes.filter { node in
                    node.nodeID != nodeID
                        && centerY > (dragRowFrames[node.nodeID]?.minY ?? .infinity) + nodeHeaderHeight / 2
                }.count
                guard let current = order.firstIndex(of: nodeID), current != target else { return }
                order.remove(at: current)
                order.insert(nodeID, at: min(target, order.count))
                withAnimation(reorderAnimation) { dragNodeOrder = order }
            }
            .onEnded { gesture in
                guard draggingNodeID == nodeID, let order = dragNodeOrder else { return }
                isFinishingDrag = true
                // Submit once on release. The binding commits through the
                // existing AudioDSPController; no second apply is needed here.
                let reordered = order.compactMap { id in nodes.first { $0.nodeID == id } }
                if reordered.map(\.nodeID) != nodes.map(\.nodeID) { nodes = reordered }

                let finalIndex = order.firstIndex(of: nodeID) ?? 0
                // Sum captured row heights in the preview order. Measurements
                // from an in-flight animation cannot move the settle target.
                let finalY = order.prefix(finalIndex).reduce(CGFloat.zero) { sum, id in
                    sum + max(nodeHeaderHeight, dragRowFrames[id]?.height ?? nodeHeaderHeight) + nodeSpacing
                }
                let initialVelocity = MotionSpec.clampedInitialVelocity(
                    MotionSpec.normalizedInitialVelocity(
                        from: dragFloatingY, to: finalY,
                        velocity: Double(gesture.velocity.height)
                    )
                )
                withAnimation(settleAnimation(initialVelocity: initialVelocity)) {
                    dragFloatingX = 0
                    dragFloatingY = finalY
                    isLifted = false
                }
                let delay = motionPolicy.visualCompletionDelay(
                    for: motionTokens[.gestureSettle], initialVelocity: initialVelocity
                )
                dragCleanupTask = Task { @MainActor in
                    if delay > .leastNonzeroMagnitude {
                        try? await Task.sleep(for: .seconds(delay))
                    }
                    guard !Task.isCancelled, draggingNodeID == nodeID else { return }
                    // Clearing the slot reconnects the wires through the
                    // gutter's own routing animation.
                    cancelDrag()
                }
            }
    }

    private func cancelDrag() {
        dragCleanupTask?.cancel()
        dragCleanupTask = nil
        draggingNodeID = nil
        dragNodeOrder = nil
        dragRowFrames = [:]
        isFinishingDrag = false
        isLifted = false
        dragFloatingX = 0
        dragFloatingY = 0
    }

    // MARK: - Bindings

    private func qualityBinding(for nodeID: UUID) -> Binding<String> {
        Binding(
            get: { nodes.first(where: { $0.nodeID == nodeID })?.quality ?? DSPNodeConfiguration.standardQuality },
            set: { quality in
                onUpdateNode(nodeID) { $0.quality = quality }
                onCommit()
            }
        )
    }

    private func equalLoudnessBinding(
        for nodeID: UUID,
        keyPath: WritableKeyPath<DSPEqualLoudnessParameters, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                nodes.first(where: { $0.nodeID == nodeID })?.equalLoudnessParameters?[keyPath: keyPath] ?? 0
            },
            set: { value in
                onUpdateNode(nodeID) { candidate in
                    var parameters = candidate.equalLoudnessParameters ?? DSPEqualLoudnessParameters()
                    parameters[keyPath: keyPath] = value
                    candidate.equalLoudnessParameters = parameters
                }
            }
        )
    }

    private func stereoWidthBinding(
        for nodeID: UUID,
        keyPath: WritableKeyPath<DSPStereoWidthParameters, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                nodes.first(where: { $0.nodeID == nodeID })?.stereoWidthParameters?[keyPath: keyPath] ?? 0
            },
            set: { value in
                onUpdateNode(nodeID) { candidate in
                    var parameters = candidate.stereoWidthParameters ?? DSPStereoWidthParameters()
                    parameters[keyPath: keyPath] = value
                    candidate.stereoWidthParameters = parameters
                }
            }
        )
    }

    private func virtualBassBinding(
        for nodeID: UUID,
        keyPath: WritableKeyPath<DSPVirtualBassParameters, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                nodes.first(where: { $0.nodeID == nodeID })?.virtualBassParameters?[keyPath: keyPath] ?? 0
            },
            set: { value in
                onUpdateNode(nodeID) { candidate in
                    var parameters = candidate.virtualBassParameters ?? DSPVirtualBassParameters()
                    parameters[keyPath: keyPath] = value
                    candidate.virtualBassParameters = parameters
                }
            }
        )
    }

    private func tubeBinding(
        for nodeID: UUID,
        keyPath: WritableKeyPath<DSPTubeParameters, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                nodes.first(where: { $0.nodeID == nodeID })?.tubeParameters?[keyPath: keyPath] ?? 0
            },
            set: { value in
                onUpdateNode(nodeID) { candidate in
                    var parameters = candidate.tubeParameters ?? DSPTubeParameters()
                    parameters[keyPath: keyPath] = value
                    candidate.tubeParameters = parameters
                }
            }
        )
    }
}

// MARK: - Add Node Menu

/// Effect picker shown in the effect-chain section header.
struct AudioDSPAddNodeMenu: View {
    let nodes: [DSPNodeConfiguration]
    let onAddNode: (DSPNodeConfiguration) -> Void

    private static let maximumScriptNodeCount = 4

    private var scriptLimitReached: Bool {
        nodes.filter { $0.typeID == DSPNodeConfiguration.scriptTypeID }.count >= Self.maximumScriptNodeCount
    }

    var body: some View {
        Menu {
            Section("均衡") {
                addButton(.parametricEQ())
                addButton(.equalLoudness())
            }
            Section("空间与音色") {
                addButton(.stereoWidth())
                addButton(.virtualBass())
                addButton(.tube())
            }
            Section("自定义") {
                addButton(.script())
                    .disabled(scriptLimitReached)
            }
        } label: {
            Label("添加效果", systemImage: "plus")
        }
        .audioDSPCapsuleButtonStyle()
        .fixedSize()
        .disabled(nodes.count >= AudioDSPConfiguration.maximumNodeCount)
    }

    private func addButton(_ node: DSPNodeConfiguration) -> some View {
        Button(
            DSPNodeDescriptor.title(for: node.typeID),
            systemImage: DSPNodeDescriptor.icon(for: node.typeID)
        ) {
            onAddNode(node)
        }
    }
}

// MARK: - Palette

/// Opaque colours for the effect rack, so a card or wire moving over another
/// never reveals what lies underneath.
///
/// Wire and mark colours come from the app foreground tiers. Those tiers are
/// defined as a source colour plus alpha; here each one is composited once
/// onto the surface it sits on, which keeps the colour system's hue and
/// lightness ladder while making the result solid.
struct DSPRackPalette {
    let endpointSurface: Color
    let nodeSurface: Color
    let bypassedNodeSurface: Color
    let bandSurface: Color
    let activeBandSurface: Color
    /// Signal wires: the tertiary foreground tier.
    let wire: Color
    /// Inactive marks on a node, such as EQ points: the quaternary tier.
    let mutedMark: Color

    init(themeStore: ThemeStore, colorScheme: ColorScheme) {
        let semantic = themeStore.semanticPalette
        let foreground = themeStore.appForegroundPalette
        let base = ColorRenderingAdapter.makeSwiftUIColor(
            HomeAmbientPalette.ambientBaseColor(
                from: semantic.ambientSurface,
                analysis: semantic.analysis,
                colorScheme: themeStore.colorScheme
            )
        )
        let isDark = colorScheme == .dark
        let ink: Color = isDark ? .white : .black
        // The settings section card tints the page with the same ink amount.
        let section = base.mix(with: ink, by: isDark ? 0.045 : 0.035, in: .device)
        let node = section.mix(with: ink, by: isDark ? 0.06 : 0.045, in: .device)

        endpointSurface = section.mix(with: ink, by: isDark ? 0.035 : 0.025, in: .device)
        nodeSurface = node
        bypassedNodeSurface = section.mix(with: ink, by: isDark ? 0.025 : 0.018, in: .device)
        bandSurface = node.mix(with: ink, by: isDark ? 0.05 : 0.035, in: .device)
        activeBandSurface = themeStore.accentColor.mix(with: node, by: 0.84)
        wire = Self.composite(foreground.tertiary, over: section)
        mutedMark = Self.composite(foreground.quaternary, over: node)
    }

    /// Flattens a translucent tier colour onto an opaque surface.
    private static func composite(_ foreground: NSColor, over surface: Color) -> Color {
        let solid = ColorRenderingAdapter.makeSwiftUIColor(foreground.withAlphaComponent(1))
        return surface.mix(with: solid, by: Double(foreground.alphaComponent), in: .device)
    }
}

// MARK: - Node Descriptors

private enum DSPRackMetrics {
    static let gutterWidth: CGFloat = 28
    static let nodeHeaderHeight: CGFloat = 44
}

/// Display names, icons and one-line summaries shared by the rack header,
/// the drag preview and the add menu.
enum DSPNodeDescriptor {
    static func icon(for typeID: String) -> String {
        switch typeID {
        case DSPNodeConfiguration.parametricEQTypeID: "slider.vertical.3"
        case DSPNodeConfiguration.equalLoudnessTypeID: "ear"
        case DSPNodeConfiguration.stereoWidthTypeID: "arrow.left.and.right"
        case DSPNodeConfiguration.virtualBassTypeID: "wave.3.forward"
        case DSPNodeConfiguration.tubeTypeID: "dial.low"
        case DSPNodeConfiguration.scriptTypeID: "curlybraces"
        default: "questionmark.square.dashed"
        }
    }

    static func title(for typeID: String) -> String {
        switch typeID {
        case DSPNodeConfiguration.parametricEQTypeID: "九段均衡器"
        case DSPNodeConfiguration.equalLoudnessTypeID: "等响补偿"
        case DSPNodeConfiguration.stereoWidthTypeID: "立体声扩展"
        case DSPNodeConfiguration.virtualBassTypeID: "虚拟低音"
        case DSPNodeConfiguration.tubeTypeID: "电子管模拟"
        case DSPNodeConfiguration.scriptTypeID: "可编程脚本"
        default: typeID
        }
    }

    /// Summaries use the same precision and units as the node's own controls.
    static func summary(for node: DSPNodeConfiguration) -> String {
        switch node.typeID {
        case DSPNodeConfiguration.parametricEQTypeID:
            let count = node.parametricEQBands?.filter(\.enabled).count ?? 0
            return "\(count) 个频段"
        case DSPNodeConfiguration.equalLoudnessTypeID:
            return node.equalLoudnessParameters.map { "强度 \(format($0.strength, digits: 2))" } ?? ""
        case DSPNodeConfiguration.stereoWidthTypeID:
            return node.stereoWidthParameters.map { "宽度 \(format($0.width, digits: 2))×" } ?? ""
        case DSPNodeConfiguration.virtualBassTypeID:
            return node.virtualBassParameters.map { "强度 \(format($0.amount, digits: 2))" } ?? ""
        case DSPNodeConfiguration.tubeTypeID:
            return node.tubeParameters.map { "驱动 \(format($0.driveDB, digits: 1)) dB" } ?? ""
        case DSPNodeConfiguration.scriptTypeID:
            let count = node.scriptParameters?.values.count ?? 0
            return count > 0 ? "\(count) 个参数" : ""
        default:
            return "此版本无法处理"
        }
    }

    static func qualityTitle(_ quality: String) -> String {
        switch quality {
        case DSPNodeConfiguration.oversampling2xQuality: "2× 过采样"
        case DSPNodeConfiguration.oversampling4xQuality: "4× 过采样"
        default: "标准"
        }
    }

    static func qualityOrder(_ lhs: String, _ rhs: String) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private static func rank(_ quality: String) -> Int {
        switch quality {
        case DSPNodeConfiguration.oversampling2xQuality: 1
        case DSPNodeConfiguration.oversampling4xQuality: 2
        default: 0
        }
    }

    private static func format(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }
}

// MARK: - Signal Wires

@MainActor
private final class DSPRackGeometryCache {
    var frames: [UUID: CGRect] = [:]
}

/// How the signal passes one rack row.
private nonisolated struct DSPWireRouting: Equatable {
    /// The signal detours around the node on the outer lane.
    var isBypassed: Bool
    /// The lane continues from a bypassed row above without returning to the bus.
    var joinsAbove: Bool
    /// The lane continues into a bypassed row below.
    var joinsBelow: Bool
    /// The wire reaches the row's top edge; otherwise it ends at the terminal.
    var connectsAbove: Bool
    /// The wire reaches the row's bottom edge; otherwise it ends at the terminal.
    var connectsBelow: Bool
    /// The node keeps its terminal; a dragged slot collapses into nothing.
    var showsTerminal: Bool
}

/// Six-component animatable vector for the wire geometry.
private nonisolated struct WireGeometry: VectorArithmetic {
    var bypass: Double
    var joinAbove: Double
    var joinBelow: Double
    var reachAbove: Double
    var reachBelow: Double
    var terminal: Double

    init(_ routing: DSPWireRouting) {
        bypass = routing.isBypassed ? 1 : 0
        joinAbove = routing.joinsAbove ? 1 : 0
        joinBelow = routing.joinsBelow ? 1 : 0
        reachAbove = routing.connectsAbove ? 1 : 0
        reachBelow = routing.connectsBelow ? 1 : 0
        terminal = routing.showsTerminal ? 1 : 0
    }

    private init(_ values: [Double]) {
        bypass = values[0]
        joinAbove = values[1]
        joinBelow = values[2]
        reachAbove = values[3]
        reachBelow = values[4]
        terminal = values[5]
    }

    private var components: [Double] {
        [bypass, joinAbove, joinBelow, reachAbove, reachBelow, terminal]
    }

    static var zero: WireGeometry { WireGeometry([0, 0, 0, 0, 0, 0]) }

    static func + (lhs: WireGeometry, rhs: WireGeometry) -> WireGeometry {
        WireGeometry(zip(lhs.components, rhs.components).map(+))
    }

    static func - (lhs: WireGeometry, rhs: WireGeometry) -> WireGeometry {
        WireGeometry(zip(lhs.components, rhs.components).map(-))
    }

    mutating func scale(by rhs: Double) {
        self = WireGeometry(components.map { $0 * rhs })
    }

    var magnitudeSquared: Double {
        components.reduce(0) { $0 + $1 * $1 }
    }
}

private struct NodeWireGutter: View {
    let routing: DSPWireRouting
    let headerHeight: CGFloat
    let wireColor: Color
    let terminalColor: Color
    let bypassedTerminalColor: Color

    var body: some View {
        GeometryReader { geometry in
            AnimatedWireGutter(
                geometry: WireGeometry(routing),
                headerHeight: headerHeight,
                wireColor: wireColor,
                terminalColor: terminalColor,
                bypassedTerminalColor: bypassedTerminalColor
            )
            .frame(width: DSPRackMetrics.gutterWidth, height: geometry.size.height)
            .motionAnimation(.control, value: routing)
        }
        .frame(width: DSPRackMetrics.gutterWidth)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Wire through one row, drawn as two halves that start at the node's
/// connection point: on the bus for an active node, on the outer lane for a
/// bypassed one. Each half grows outward to the row edge, so retracting a
/// half pulls the wire back into the connection point with a round tip.
/// Rows draw inside their own bounds and adjacent halves meet exactly.
private struct AnimatedWireGutter: View, Animatable {
    var geometry: WireGeometry
    let headerHeight: CGFloat
    let wireColor: Color
    let terminalColor: Color
    let bypassedTerminalColor: Color

    private nonisolated static let busX: CGFloat = 14
    private nonisolated static let laneX: CGFloat = 3
    private nonisolated static let lineWidth: CGFloat = 1.5
    private nonisolated static let terminalRadius: CGFloat = 3
    /// Vertical distance from the connection point at which the lane leaves
    /// or rejoins the bus.
    private nonisolated static let detourReach: CGFloat = 20

    var animatableData: WireGeometry {
        get { geometry }
        set { geometry = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let style = StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round)
            let bypass = Self.unit(geometry.bypass)
            let offset = Self.busX - Self.laneX
            let center = CGPoint(x: Self.busX - offset * bypass, y: headerHeight / 2)
            let topX = Self.busX - offset * Self.unit(geometry.joinAbove)
            let bottomX = Self.busX - offset * Self.unit(geometry.joinBelow)
            let exitY = center.y - Self.detourReach
            let returnY = center.y + Self.detourReach
            let handle = Self.detourReach * 0.6

            var upper = Path()
            upper.move(to: center)
            upper.addCurve(
                to: CGPoint(x: topX, y: exitY),
                control1: CGPoint(x: center.x, y: center.y - handle),
                control2: CGPoint(x: topX, y: exitY + handle)
            )
            upper.addLine(to: CGPoint(x: topX, y: 0))

            var lower = Path()
            lower.move(to: center)
            lower.addCurve(
                to: CGPoint(x: bottomX, y: returnY),
                control1: CGPoint(x: center.x, y: center.y + handle),
                control2: CGPoint(x: bottomX, y: returnY - handle)
            )
            lower.addLine(to: CGPoint(x: bottomX, y: size.height))

            for (half, reach) in [(upper, geometry.reachAbove), (lower, geometry.reachBelow)] {
                let amount = Self.unit(reach)
                guard amount > 0.001 else { continue }
                let visible = amount < 0.999 ? half.trimmedPath(from: 0, to: amount) : half
                // The last stretch of a retraction fades out while it shortens,
                // so the tip never lingers as a dot at its shortest length.
                context.fill(
                    visible.strokedPath(style),
                    with: .color(wireColor.opacity(Self.fadeNearEnd(amount)))
                )
            }

            // The terminal stays on the bus at the node. Bypassing only bends
            // the wire away and softens the terminal to the wire tone; a
            // dragged slot shrinks and fades its terminal as the wire gathers.
            let terminal = Self.unit(geometry.terminal)
            if terminal > 0.001 {
                let radius = Self.terminalRadius * (0.35 + 0.65 * terminal)
                let dot = CGRect(
                    x: Self.busX - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                let color = terminalColor.mix(with: bypassedTerminalColor, by: Double(bypass))
                context.fill(
                    Path(ellipseIn: dot),
                    with: .color(color.opacity(Self.fadeNearEnd(terminal)))
                )
            }
        }
    }

    private nonisolated static func unit(_ value: Double) -> CGFloat {
        CGFloat(min(1, max(0, value)))
    }

    /// 1 for most of the range, easing to 0 over the final 35 percent.
    nonisolated static func fadeNearEnd(_ amount: CGFloat) -> Double {
        let t = Double(min(1, max(0, amount / 0.35)))
        return t * t * (3 - 2 * t)
    }
}

/// Straight bus between an endpoint card and the node list. When the slot
/// next to it is detached, the segment retracts toward its endpoint.
private struct BusWireSegment: View {
    enum Anchor { case top, bottom }

    let anchor: Anchor
    let isConnected: Bool
    let color: Color

    var body: some View {
        AnimatedBusWire(reach: isConnected ? 1 : 0, anchor: anchor, color: color)
            .frame(width: DSPRackMetrics.gutterWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
            .motionAnimation(.control, value: isConnected)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct AnimatedBusWire: View, Animatable {
    var reach: Double
    let anchor: BusWireSegment.Anchor
    let color: Color

    var animatableData: Double {
        get { reach }
        set { reach = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let amount = CGFloat(min(1, max(0, reach)))
            guard amount > 0.001 else { return }
            let x: CGFloat = 14
            let length = size.height * amount
            var path = Path()
            switch anchor {
            case .top:
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: length))
            case .bottom:
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x, y: size.height - length))
            }
            let style = StrokeStyle(lineWidth: 1.5, lineCap: amount < 0.999 ? .round : .butt)
            context.fill(
                path.strokedPath(style),
                with: .color(color.opacity(AnimatedWireGutter.fadeNearEnd(amount)))
            )
        }
    }
}
