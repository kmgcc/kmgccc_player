//
//  AudioDSPLinearNodeRack.swift
//  myPlayer2
//
//  Linear Node Rack for audio DSP effect chain.
//  Expresses processing order via a continuous vertical signal bus and connection terminals.
//  Supports bypass wire routing (detour around disabled nodes), compact node summaries,
//  smooth parameter expansion, and fluid drag reordering.
//

import MotionKit
import SwiftUI

struct AudioDSPLinearNodeRack: View {
    @Binding var nodes: [DSPNodeConfiguration]
    let configuration: AudioDSPConfiguration
    let format: DSPAudioFormat?
    let headroomDB: Double?
    @Binding var expandedNodeIDs: Set<UUID>
    @Binding var inputTrimDB: Double
    @Binding var outputTrimDB: Double
    @Binding var headroomMode: DSPHeadroomMode
    @Binding var headroomMarginDB: Double

    let onCommit: () -> Void
    let onAddNode: (DSPNodeConfiguration) -> Void
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
    @State private var isFinishingDrag = false
    @State private var dragCleanupTask: Task<Void, Never>?
    @State private var rowGeometry = DSPRackGeometryCache()

    private let rackSpace = "dspLinearNodeRackCoordinateSpace"
    private let nodeHeaderHeight: CGFloat = 44
    private let nodeSpacing: CGFloat = 12
    private let dragHorizontalDamping: CGFloat = 0.4
    private let dragHorizontalLimit: CGFloat = 24

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
        VStack(alignment: .leading, spacing: 0) {
            inputEndpointView

            // Continuous vertical signal line between input and first node
            rackConnectingWire(height: 18)

            // Reorderable nodes rack
            nodesRackList
                .coordinateSpace(name: rackSpace)

            // Continuous vertical signal line between last node and output
            rackConnectingWire(height: 18)

            outputEndpointView

            addNodeBar
                .padding(.top, 16)
        }
        .onDisappear(perform: cancelDrag)
        .onChange(of: nodes.map(\.nodeID)) { _, _ in
            if !isFinishingDrag { cancelDrag() }
            rowGeometry.frames = rowGeometry.frames.filter { id, _ in nodes.contains { $0.nodeID == id } }
        }
    }

    // MARK: - Input Endpoint (Audio Input Stage)

    private var inputEndpointView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(themeStore.accentColor)

                Text("输入阶段")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Text("原始输入")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            DSPRangeSliderRow(
                title: "输入增益",
                value: $inputTrimDB,
                range: -24...24,
                step: 0.1,
                onCommit: onCommit
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(endpointBackground)
    }

    // MARK: - Output Endpoint (Audio Output Stage)

    private var outputEndpointView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(themeStore.accentColor)

                Text("输出阶段")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if let headroomDB {
                    Text("预估余量 \(headroomDB.formatted(.number.precision(.fractionLength(1)))) dB")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            DSPRangeSliderRow(
                title: "输出增益",
                value: $outputTrimDB,
                range: -24...24,
                step: 0.1,
                onCommit: onCommit
            )

            CapsulePicker(
                label: "余量策略",
                options: DSPHeadroomMode.allCases,
                selection: $headroomMode,
                displayName: { $0 == .automatic ? "自动" : "关闭" }
            )

            if headroomMode == .automatic {
                DSPRangeSliderRow(
                    title: "余量安全边距",
                    value: $headroomMarginDB,
                    range: 0...12,
                    step: 0.1,
                    unit: "dB",
                    onCommit: onCommit
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(endpointBackground)
    }

    private var endpointBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.025))
    }

    // MARK: - Nodes Rack List

    @ViewBuilder
    private var nodesRackList: some View {
        if nodes.isEmpty {
            emptyRackPlaceholder
        } else {
            VStack(spacing: 0) {
                ForEach(Array(rackNodes.enumerated()), id: \.element.nodeID) { index, node in
                    nodeRackRow(node: node, index: index)
                }
            }
            .overlay(alignment: .top) {
                if let draggingID = draggingNodeID,
                   let draggingNode = nodes.first(where: { $0.nodeID == draggingID }) {
                    let dragIndex = rackNodes.firstIndex(where: { $0.nodeID == draggingID }) ?? 0
                    floatingNodeCard(node: draggingNode, index: dragIndex)
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

    private var emptyRackPlaceholder: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("直通无效果")
                    .font(.system(size: 13, weight: .medium))
                Text("点击下方添加效果向处理链插入节点")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .padding(.leading, 28)
        .background(alignment: .leading) {
            themeStore.accentColor.opacity(0.45)
                .frame(width: 1.5)
                .padding(.leading, 13.25)
        }
    }

    // MARK: - Node Rack Row

    private func nodeRackRow(node: DSPNodeConfiguration, index: Int) -> some View {
        let isDragging = draggingNodeID == node.nodeID
        let isExpanded = expandedNodeIDs.contains(node.nodeID)
        let isLast = index == rackNodes.count - 1

        return nodeCardContent(node: node, index: index, isExpanded: isExpanded)
            .opacity(isDragging ? 0 : 1)
            .background {
                if isDragging {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.02))
                }
            }
            .padding(.leading, 28)
            // Each row owns the following gap, so its wire stays inside its
            // drawing bounds and meets the next row without clipped extensions.
            .padding(.bottom, isLast ? 0 : nodeSpacing)
            .background(alignment: .leading) {
                NodeWireGutter(
                    isBypassed: !node.enabled,
                    headerHeight: nodeHeaderHeight,
                    accentColor: themeStore.accentColor
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

    // MARK: - Node Card Content

    private func nodeCardContent(
        node: DSPNodeConfiguration,
        index: Int,
        isExpanded: Bool
    ) -> some View {
        let isBypassed = !node.enabled

        return VStack(alignment: .leading, spacing: 0) {
            // Node Header
            HStack(spacing: 8) {
                // Node Index
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(isBypassed ? .secondary.opacity(0.6) : themeStore.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(isBypassed
                                ? Color.secondary.opacity(0.08)
                                : themeStore.accentColor.opacity(0.12)
                            )
                    )

                // Node Icon
                Image(systemName: nodeIcon(for: node.typeID))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isBypassed ? .secondary : .primary)
                    .frame(width: 18)

                // Title & Summary
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(nodeTitle(for: node.typeID))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isBypassed ? .secondary : .primary)

                        if isBypassed {
                            Text("已旁路")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        }
                    }

                    Text(nodeSummary(for: node))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // Channel policy tag
                Text(policyShortTitle(node.channelPolicy))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))

                // Bypass / Enable Switch
                Toggle("", isOn: Binding(
                    get: { node.enabled },
                    set: { enabled in
                        onUpdateNode(node.nodeID) { $0.enabled = enabled }
                        onCommit()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("\(nodeTitle(for: node.typeID))启用状态")

                // Remove button
                Button {
                    withAnimation(reorderAnimation) {
                        onRemoveNode(node.nodeID)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("移除节点")
                .accessibilityLabel("移除\(nodeTitle(for: node.typeID))")

                // Drag handle
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.7))
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .highPriorityGesture(reorderGesture(for: node.nodeID))
                    .help("拖动排序")
                    .accessibilityLabel("拖动排序")

                // Expand / Collapse chevron
                Button {
                    withAnimation(reorderAnimation) {
                        if isExpanded {
                            expandedNodeIDs.remove(node.nodeID)
                        } else {
                            expandedNodeIDs.insert(node.nodeID)
                        }
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起参数" : "展开参数")
            }
            .frame(height: nodeHeaderHeight)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(reorderAnimation) {
                    if isExpanded {
                        expandedNodeIDs.remove(node.nodeID)
                    } else {
                        expandedNodeIDs.insert(node.nodeID)
                    }
                }
            }

            // Expanded Editor
            if isExpanded {
                Divider()
                    .padding(.horizontal, 10)

                nodeDetailEditor(node: node, index: index)
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark
                    ? (isBypassed ? 0.025 : 0.05)
                    : (isBypassed ? 0.018 : 0.038)
                ))
        )
        .opacity(isBypassed ? 0.72 : 1.0)
        .motionAnimation(.control, value: isExpanded)
    }

    // MARK: - Detailed Node Editors

    @ViewBuilder
    private func nodeDetailEditor(node: DSPNodeConfiguration, index: Int) -> some View {
        if node.typeID == DSPNodeConfiguration.parametricEQTypeID,
           let bands = node.parametricEQBands {
            VStack(alignment: .leading, spacing: 12) {
                CapsulePicker(
                    label: "声道范围",
                    options: ["fullRange", "allChannels"],
                    selection: channelPolicyBinding(for: node.nodeID),
                    displayName: { $0 == "fullRange" ? "全频" : "所有声道" }
                )

                AudioDSPEQEditor(
                    configuration: configuration,
                    node: node,
                    bands: bands,
                    format: format,
                    headroomDB: headroomDB,
                    onBandChange: { bandIndex, band in
                        onUpdateNode(node.nodeID) { candidate in
                            guard var b = candidate.parametricEQBands,
                                  b.indices.contains(bandIndex) else { return }
                            b[bandIndex] = band
                            candidate.parametricEQBands = b
                        }
                    },
                    onCommit: onCommit
                )
                .equatable()
            }
        } else if node.typeID == DSPNodeConfiguration.equalLoudnessTypeID,
                  let parameters = node.equalLoudnessParameters {
            equalLoudnessEditor(node: node, parameters: parameters)
        } else if [DSPNodeConfiguration.stereoWidthTypeID, DSPNodeConfiguration.virtualBassTypeID, DSPNodeConfiguration.tubeTypeID].contains(node.typeID) {
            nativeEffectsEditor(node: node)
        } else if node.typeID == DSPNodeConfiguration.scriptTypeID {
            scriptEditor(node: node, index: index)
        } else {
            Text("该节点暂无更多参数。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func equalLoudnessEditor(node: DSPNodeConfiguration, parameters: DSPEqualLoudnessParameters) -> some View {
        let context = appSession.audioProcessingGlobalsController.equalLoudnessContext
        return VStack(alignment: .leading, spacing: 12) {
            CapsulePicker(
                label: "声道范围",
                options: ["fullRange", "allChannels"],
                selection: channelPolicyBinding(for: node.nodeID),
                displayName: { $0 == "fullRange" ? "全频" : "所有声道" }
            )

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

    private func nativeEffectsEditor(node: DSPNodeConfiguration) -> some View {
        let policies = DSPNodeConfiguration.supportedChannelPolicies(forTypeID: node.typeID)
        let qualities = DSPNodeConfiguration.supportedQualities(forTypeID: node.typeID)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                CapsulePicker(
                    label: "声道范围",
                    options: Array(policies),
                    selection: channelPolicyBinding(for: node.nodeID),
                    displayName: policyShortTitle
                )

                if qualities.count > 1 {
                    CapsulePicker(
                        label: "质量",
                        options: Array(qualities),
                        selection: qualityBinding(for: node.nodeID),
                        displayName: qualityShortTitle
                    )
                }
            }

            if node.typeID == DSPNodeConfiguration.stereoWidthTypeID {
                DSPRangeSliderRow(
                    title: "宽度",
                    value: stereoWidthBinding(for: node.nodeID, keyPath: \.width),
                    range: DSPStereoWidthParameters.widthRange,
                    step: 0.01,
                    unit: "×",
                    onCommit: onCommit
                )
                DSPRangeSliderRow(
                    title: "增益",
                    value: stereoWidthBinding(for: node.nodeID, keyPath: \.outputTrimDB),
                    range: DSPStereoWidthParameters.outputTrimRange,
                    step: 0.1,
                    onCommit: onCommit
                )
            } else if node.typeID == DSPNodeConfiguration.virtualBassTypeID {
                DSPRangeSliderRow(
                    title: "强度",
                    value: virtualBassBinding(for: node.nodeID, keyPath: \.amount),
                    range: DSPVirtualBassParameters.amountRange,
                    step: 0.01,
                    unit: "",
                    onCommit: onCommit
                )
                DSPRangeSliderRow(
                    title: "混合",
                    value: virtualBassBinding(for: node.nodeID, keyPath: \.mix),
                    range: DSPVirtualBassParameters.mixRange,
                    step: 0.01,
                    unit: "",
                    onCommit: onCommit
                )
            } else if node.typeID == DSPNodeConfiguration.tubeTypeID {
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
                    onCommit: onCommit
                )
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

    private func scriptEditor(node: DSPNodeConfiguration, index: Int) -> some View {
        AudioDSPScriptNodeCard(
            node: node,
            index: index,
            nodeCount: nodes.count,
            format: scriptCompileFormat,
            dspController: appSession.audioDSPController,
            scriptController: appSession.audioDSPScriptController,
            isExpanded: .constant(true),
            onEnabledChange: { enabled in
                onUpdateNode(node.nodeID) { $0.enabled = enabled }
                onCommit()
            },
            onChannelPolicyChange: { policy in
                onUpdateNode(node.nodeID) { $0.channelPolicy = policy }
                onCommit()
            },
            onCommit: onCommit,
            onMove: { _ in },
            onRemove: { onRemoveNode(node.nodeID) }
        )
    }

    // MARK: - Floating Drag Card

    private func floatingNodeCard(node: DSPNodeConfiguration, index: Int) -> some View {
            HStack(spacing: 8) {
                Image(systemName: nodeIcon(for: node.typeID))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(node.enabled ? themeStore.accentColor : .secondary)

                Text(nodeTitle(for: node.typeID))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(node.enabled ? .primary : .secondary)

                Text(nodeSummary(for: node))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: nodeHeaderHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: themeStore.semanticPalette.ambientSurface))
            )
            .padding(.leading, 28)
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
                    dragNodeOrder = nodes.map(\.nodeID)
                    draggingNodeID = nodeID
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
                }
                let delay = motionPolicy.visualCompletionDelay(
                    for: motionTokens[.gestureSettle], initialVelocity: initialVelocity
                )
                dragCleanupTask = Task { @MainActor in
                    if delay > .leastNonzeroMagnitude {
                        try? await Task.sleep(for: .seconds(delay))
                    }
                    guard !Task.isCancelled, draggingNodeID == nodeID else { return }
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
        dragFloatingX = 0
        dragFloatingY = 0
    }

    // MARK: - Signal Bus Wires

    private func rackConnectingWire(height: CGFloat) -> some View {
        HStack(spacing: 0) {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 14, y: 0))
                path.addLine(to: CGPoint(x: 14, y: height))
                let strokeStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                context.fill(path.strokedPath(strokeStyle), with: .color(themeStore.accentColor.opacity(0.45)))
            }
            .frame(width: 28, height: height)

            Spacer()
        }
    }

    // MARK: - Add Node Menu

    private var addNodeBar: some View {
        Menu {
            Button("九段均衡器") { onAddNode(.parametricEQ()) }
            Button("等响补偿") { onAddNode(.equalLoudness()) }
            Button("立体声扩展") { onAddNode(.stereoWidth()) }
            Button("虚拟低音") { onAddNode(.virtualBass()) }
            Button("电子管模拟") { onAddNode(.tube()) }
            Button("可编程脚本") { onAddNode(.script()) }
                .disabled(nodes.filter { $0.typeID == DSPNodeConfiguration.scriptTypeID }.count >= 4)
        } label: {
            Label("添加处理节点", systemImage: "plus")
        }
        .audioDSPCapsuleButtonStyle()
        .disabled(nodes.count >= AudioDSPConfiguration.maximumNodeCount)
    }

    // MARK: - Helpers & Bindings

    private func channelPolicyBinding(for nodeID: UUID) -> Binding<String> {
        Binding(
            get: { nodes.first(where: { $0.nodeID == nodeID })?.channelPolicy ?? "fullRange" },
            set: { val in
                onUpdateNode(nodeID) { $0.channelPolicy = val }
                onCommit()
            }
        )
    }

    private func qualityBinding(for nodeID: UUID) -> Binding<String> {
        Binding(
            get: { nodes.first(where: { $0.nodeID == nodeID })?.quality ?? "standard" },
            set: { val in
                onUpdateNode(nodeID) { $0.quality = val }
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
            set: { val in
                onUpdateNode(nodeID) { candidate in
                    var p = candidate.equalLoudnessParameters ?? DSPEqualLoudnessParameters()
                    p[keyPath: keyPath] = val
                    candidate.equalLoudnessParameters = p
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
            set: { val in
                onUpdateNode(nodeID) { candidate in
                    var p = candidate.stereoWidthParameters ?? DSPStereoWidthParameters()
                    p[keyPath: keyPath] = val
                    candidate.stereoWidthParameters = p
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
            set: { val in
                onUpdateNode(nodeID) { candidate in
                    var p = candidate.virtualBassParameters ?? DSPVirtualBassParameters()
                    p[keyPath: keyPath] = val
                    candidate.virtualBassParameters = p
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
            set: { val in
                onUpdateNode(nodeID) { candidate in
                    var p = candidate.tubeParameters ?? DSPTubeParameters()
                    p[keyPath: keyPath] = val
                    candidate.tubeParameters = p
                }
            }
        )
    }

    private func nodeIcon(for typeID: String) -> String {
        switch typeID {
        case DSPNodeConfiguration.parametricEQTypeID: return "waveform"
        case DSPNodeConfiguration.equalLoudnessTypeID: return "speaker.wave.2"
        case DSPNodeConfiguration.stereoWidthTypeID: return "arrow.left.and.right"
        case DSPNodeConfiguration.virtualBassTypeID: return "wave.3.forward"
        case DSPNodeConfiguration.tubeTypeID: return "dial.low"
        case DSPNodeConfiguration.scriptTypeID: return "curlybraces"
        default: return "gearshape"
        }
    }

    private func nodeTitle(for typeID: String) -> String {
        switch typeID {
        case DSPNodeConfiguration.parametricEQTypeID: return "九段均衡器"
        case DSPNodeConfiguration.equalLoudnessTypeID: return "等响补偿"
        case DSPNodeConfiguration.stereoWidthTypeID: return "立体声扩展"
        case DSPNodeConfiguration.virtualBassTypeID: return "虚拟低音"
        case DSPNodeConfiguration.tubeTypeID: return "电子管模拟"
        case DSPNodeConfiguration.scriptTypeID: return "自定义脚本"
        default: return typeID
        }
    }

    private func nodeSummary(for node: DSPNodeConfiguration) -> String {
        switch node.typeID {
        case DSPNodeConfiguration.parametricEQTypeID:
            let count = node.parametricEQBands?.filter(\.enabled).count ?? 0
            return "\(count) 频段启用"
        case DSPNodeConfiguration.equalLoudnessTypeID:
            if let p = node.equalLoudnessParameters {
                return "强度 \(Int(p.strength * 100))%"
            }
            return "等响补偿"
        case DSPNodeConfiguration.stereoWidthTypeID:
            if let p = node.stereoWidthParameters {
                return "宽幅 \(Int(p.width * 100))%"
            }
            return "立体声扩展"
        case DSPNodeConfiguration.virtualBassTypeID:
            if let p = node.virtualBassParameters {
                return "强度 \(Int(p.amount * 100))%"
            }
            return "虚拟低音"
        case DSPNodeConfiguration.tubeTypeID:
            if let p = node.tubeParameters {
                return "驱动 \(p.driveDB.formatted(.number.precision(.fractionLength(1)))) dB"
            }
            return "电子管模拟"
        case DSPNodeConfiguration.scriptTypeID:
            return "自定义 VM 脚本"
        default:
            return ""
        }
    }

    private func policyShortTitle(_ policy: String) -> String {
        switch policy {
        case "frontPair": return "前置声道"
        case "allChannels": return "所有声道"
        default: return "全频"
        }
    }

    private func qualityShortTitle(_ quality: String) -> String {
        switch quality {
        case DSPNodeConfiguration.oversampling2xQuality: return "2× 过采样"
        case DSPNodeConfiguration.oversampling4xQuality: return "4× 过采样"
        default: return "标准"
        }
    }
}

// MARK: - Node Signal Wire & Bypass Gutter

@MainActor
private final class DSPRackGeometryCache {
    var frames: [UUID: CGRect] = [:]
}

// Signal wires express routing, rather than card hierarchy. Drawing is
// bounded by the owning row (including its trailing gap), with round terminals.
private struct AnimatedWireGutter: View, Animatable {
    var bypassProgress: Double
    let headerHeight: CGFloat
    let accentColor: Color

    var animatableData: Double {
        get { bypassProgress }
        set { bypassProgress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let midX: CGFloat = 14
            let centerY = headerHeight / 2
            let progress = min(1, max(0, bypassProgress))
            let detourX = midX - 9 * progress
            let startY = centerY - 18
            let endY = centerY + 18

            var path = Path()
            path.move(to: CGPoint(x: midX, y: 0))
            path.addLine(to: CGPoint(x: midX, y: startY))
            path.addCurve(
                to: CGPoint(x: detourX, y: centerY),
                control1: CGPoint(x: midX, y: startY + 10),
                control2: CGPoint(x: detourX, y: centerY - 10)
            )
            path.addCurve(
                to: CGPoint(x: midX, y: endY),
                control1: CGPoint(x: detourX, y: centerY + 10),
                control2: CGPoint(x: midX, y: endY - 10)
            )
            path.addLine(to: CGPoint(x: midX, y: size.height))
            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            context.fill(path.strokedPath(style), with: .color(accentColor.opacity(0.45)))

            let dot = CGRect(x: midX - 3, y: centerY - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: dot), with: .color(accentColor.opacity(1 - progress)))
            let ring = Path(ellipseIn: dot).strokedPath(StrokeStyle(lineWidth: 1.2))
            context.fill(ring, with: .color(.secondary.opacity(0.35 * progress)))
        }
    }
}

private struct NodeWireGutter: View {
    let isBypassed: Bool
    let headerHeight: CGFloat
    let accentColor: Color

    var body: some View {
        GeometryReader { geometry in
            AnimatedWireGutter(
                bypassProgress: isBypassed ? 1 : 0,
                headerHeight: headerHeight,
                accentColor: accentColor
            )
            .frame(width: 28, height: geometry.size.height)
            .motionAnimation(.control, value: isBypassed)
        }
        .frame(width: 28)
        .allowsHitTesting(false)
    }
}
