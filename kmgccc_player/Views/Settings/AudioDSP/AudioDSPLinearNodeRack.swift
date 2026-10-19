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
//  reconnects at release while the node falls into its new slot.
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
    @Binding var isHeadroomEnabled: Bool
    @Binding var maximumAttenuationDB: Double
    @Binding var isLimiterEnabled: Bool
    @Binding var limiterCeilingDB: Double
    let equalLoudness: DSPEqualLoudnessStage
    /// False while another device's sound is shown: live volume and
    /// calibration belong to the device now playing.
    let isLive: Bool

    let onCommit: () -> Void
    let onRemoveNode: (UUID) -> Void
    let onUpdateNode: (UUID, (inout DSPNodeConfiguration) -> Void) -> Void
    let onUpdateEqualLoudness: ((inout DSPEqualLoudnessStage) -> Void) -> Void

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
    @State private var isCalibrating = false
    @State private var isEqualLoudnessExpanded = false
    @State private var isLimiterExpanded = false

    @State private var enclosingScrollView: NSScrollView?
    @State private var rackCoordinateView: NSView?
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var autoScrollVelocity: CGFloat = 0
    @State private var dragPointerYOffset: CGFloat = 0

    private let rackSpace = "dspLinearNodeRackCoordinateSpace"
    private let nodeHeaderHeight: CGFloat = DSPRackMetrics.nodeHeaderHeight
    private let nodeSpacing: CGFloat = 10
    private let dragHorizontalDamping: CGFloat = 0.4
    private let dragHorizontalLimit: CGFloat = 24
    private let liftedScale: CGFloat = 1.015
    private let autoScrollEdgeThreshold: CGFloat = 100
    private let autoScrollBottomEdgeThreshold: CGFloat = 130
    private let autoScrollMinVelocity: CGFloat = 30
    private let autoScrollMaxVelocity: CGFloat = 2000
    private let autoScrollOverdriveMaxVelocity: CGFloat = 2800
    private let autoScrollFrameInterval: UInt64 = 16_000_000

    private var palette: DSPRackPalette {
        DSPRackPalette(themeStore: themeStore, colorScheme: colorScheme)
    }

    private var isProcessingEnabled: Bool {
        isLive && appSession.audioDSPController.configuration.enabled
    }

    private var rackNodes: [DSPNodeConfiguration] {
        guard let order = dragNodeOrder else { return nodes }
        let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.nodeID, $0) })
        return order.compactMap { nodesByID[$0] }
    }

    /// The node whose wiring is detached from the chain. Release already fixes
    /// the landing slot, so the wires reconnect while the card is still falling.
    private var detachedNodeID: UUID? {
        isFinishingDrag ? nil : draggingNodeID
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
        let slotIndex = detachedNodeID.flatMap { id in ordered.firstIndex { $0.nodeID == id } }

        VStack(alignment: .leading, spacing: 0) {
            inputEndpointView(palette: palette)
            BusWireSegment(anchor: .top, isConnected: slotIndex != 0, color: palette.wire)
                .frame(height: 14)
            nodesRackList(ordered: ordered, palette: palette)
                .coordinateSpace(name: rackSpace)
                .background(
                    DSPRackScrollViewResolver { scrollView, coordinateView in
                        enclosingScrollView = scrollView
                        rackCoordinateView = coordinateView
                    }
                )
            BusWireSegment(
                anchor: .bottom,
                isConnected: slotIndex == nil || slotIndex != ordered.count - 1,
                color: palette.wire
            )
            .frame(height: 14)
            equalLoudnessStageView(palette: palette)
            BusWireSegment(anchor: .top, isConnected: true, color: palette.wire)
                .frame(height: 14)
            limiterStageView(palette: palette)
            BusWireSegment(anchor: .top, isConnected: true, color: palette.wire)
                .frame(height: 14)
            outputEndpointView(palette: palette)
        }
        .onDisappear(perform: cancelDrag)
        .onChange(of: nodes.map(\.nodeID)) { _, _ in
            if !isFinishingDrag { cancelDrag() }
            rowGeometry.frames = rowGeometry.frames.filter { id, _ in nodes.contains { $0.nodeID == id } }
        }
        .sheet(isPresented: $isCalibrating) {
            EqualLoudnessCalibrationDialog(
                controller: appSession.equalLoudnessController,
                onSave: { calibration in
                    onUpdateEqualLoudness { $0.calibration = calibration }
                    onCommit()
                }
            ) {
                isCalibrating = false
            }
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
            trailing: isHeadroomEnabled ? headroomDB.map {
                "衰减 \(abs($0).formatted(.number.precision(.fractionLength(1)))) dB"
            } : nil,
            palette: palette
        ) {
            DSPRangeSliderRow(
                title: "输出增益",
                value: $outputTrimDB,
                range: -24...24,
                step: 0.1,
                onCommit: onCommit
            )

            SettingsSwitchRow(title: "余量保护", isOn: $isHeadroomEnabled)

            if isHeadroomEnabled {
                DSPRangeSliderRow(
                    title: "最大衰减",
                    value: $maximumAttenuationDB,
                    range: DSPHeadroomConfiguration.maximumAttenuationRange,
                    step: 0.1,
                    onCommit: onCommit
                )
            }
        }
    }

    /// Fixed between the equal-loudness stage and the output; it can be
    /// switched and expanded but never moved or removed.
    private func limiterStageView(palette: DSPRackPalette) -> some View {
        let title = "安全限幅"
        let isBypassed = !isLimiterEnabled
        let ceilingMagnitude = abs(limiterCeilingDB).formatted(.number.precision(.fractionLength(1)))
        let ceiling = limiterCeilingDB < -0.05 ? "−\(ceilingMagnitude)" : ceilingMagnitude
        let warning = appSession.audioDSPController.limiterWarning
        let isWarningActive = isLimiterEnabled && isProcessingEnabled && warning.isWarningActive
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(reorderAnimation) { isLimiterExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isLimiterExpanded ? 90 : 0))
                            .frame(width: 12)
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isBypassed ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(themeStore.accentColor))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(isBypassed ? .secondary : .primary)
                            Text("上限 \(ceiling) dB")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(isLimiterExpanded ? "已展开" : "已收起")

                if isWarningActive {
                    DSPLimiterWarningIndicator(reductionDB: warning.lastReductionDB)
                        .transition(.opacity)
                }

                Toggle("", isOn: $isLimiterEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel("启用\(title)")
            }
            .animation(reorderAnimation, value: isWarningActive)
            .onChange(of: isLimiterEnabled) { _, enabled in
                if !enabled {
                    appSession.audioDSPController.limiterWarning.reset()
                }
            }
            .frame(height: nodeHeaderHeight)
            .padding(.leading, 12)
            .padding(.trailing, 12)

            if isLimiterExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    DSPRangeSliderRow(
                        title: "上限",
                        value: $limiterCeilingDB,
                        range: DSPLimiterConfiguration.ceilingRange,
                        step: 0.1,
                        onCommit: onCommit
                    )
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .background(
            DSPProcessingLoadSurface(presentation: appSession.audioDSPController.processingLoad,
                nodeID: DSPLimiterConfiguration.nodeID, isEnabled: isLimiterEnabled && isProcessingEnabled,
                isLive: isLive, baseColor: palette.endpointSurface,
                isExpanded: isLimiterExpanded, headerHeight: nodeHeaderHeight)
        )
    }

    /// Fixed between the nodes and the output; it can be switched and
    /// expanded but never moved or removed.
    private func equalLoudnessStageView(palette: DSPRackPalette) -> some View {
        let title = "等响补偿"
        let isBypassed = !equalLoudness.enabled
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(reorderAnimation) { isEqualLoudnessExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isEqualLoudnessExpanded ? 90 : 0))
                            .frame(width: 12)
                        Image(systemName: "ear")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isBypassed ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(themeStore.accentColor))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(isBypassed ? .secondary : .primary)
                            Text("强度 \(equalLoudness.parameters.strength.formatted(.number.precision(.fractionLength(2))))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(isEqualLoudnessExpanded ? "已展开" : "已收起")

                Toggle("", isOn: Binding(
                    get: { equalLoudness.enabled },
                    set: { enabled in
                        guard enabled != equalLoudness.enabled else { return }
                        onUpdateEqualLoudness { $0.enabled = enabled }
                        onCommit()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("启用\(title)")
            }
            .frame(height: nodeHeaderHeight)
            .padding(.leading, 12)
            .padding(.trailing, 12)

            if isEqualLoudnessExpanded {
                equalLoudnessEditor
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .background(
            DSPProcessingLoadSurface(presentation: appSession.audioDSPController.processingLoad,
                nodeID: DSPEqualLoudnessStage.nodeID, isEnabled: equalLoudness.enabled && isProcessingEnabled,
                isLive: isLive, baseColor: palette.endpointSurface,
                isExpanded: isEqualLoudnessExpanded, headerHeight: nodeHeaderHeight)
        )
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
            Text("在右上角点击“添加效果”以开始")
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
        let isSlot = node.nodeID == detachedNodeID
        let previous = index > 0 ? ordered[index - 1] : nil
        let next = index + 1 < ordered.count ? ordered[index + 1] : nil
        let previousIsSlot = previous.map { $0.nodeID == detachedNodeID } ?? false
        let nextIsSlot = next.map { $0.nodeID == detachedNodeID } ?? false
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
            DSPProcessingLoadSurface(presentation: appSession.audioDSPController.processingLoad,
                nodeID: node.nodeID, isEnabled: node.enabled && isProcessingEnabled, isLive: isLive,
                baseColor: node.enabled ? palette.nodeSurface : palette.bypassedNodeSurface,
                isExpanded: isExpanded, headerHeight: nodeHeaderHeight)
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
        case _ where DSPNodeConfiguration.nativeEffectTypeIDs.contains(node.typeID):
            AudioDSPNativeEffectEditor(
                node: node,
                isProcessing: node.enabled && isProcessingEnabled,
                outputKind: appSession.equalLoudnessController.routedOutputKind,
                onUpdateNode: onUpdateNode,
                onCommit: onCommit
            )
            .equatable()
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

    private var equalLoudnessEditor: some View {
        let context = appSession.equalLoudnessController.context
        return VStack(alignment: .leading, spacing: 10) {
            if isLive {
                AudioDSPEqualLoudnessResponseCurve(
                    stage: equalLoudness,
                    context: context,
                    sampleRate: format?.sampleRate ?? 48_000,
                    accentColor: themeStore.accentColor
                )
                .equatable()

                AudioDSPEqualLoudnessStatus(
                    stage: equalLoudness,
                    controller: appSession.equalLoudnessController,
                    onCalibrate: { isCalibrating = true },
                    onRemoveCalibration: {
                        onUpdateEqualLoudness { $0.calibration = nil }
                        onCommit()
                    }
                )
            }

            DSPRangeSliderRow(
                title: "强度",
                value: Binding(
                    get: { equalLoudness.parameters.strength },
                    set: { value in onUpdateEqualLoudness { $0.parameters.strength = value } }
                ),
                range: DSPEqualLoudnessParameters.strengthRange,
                step: 0.01,
                unit: "",
                fractionDigits: 2,
                onCommit: onCommit
            )
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
                DSPProcessingLoadSurface(presentation: appSession.audioDSPController.processingLoad,
                    nodeID: node.nodeID, isEnabled: node.enabled && isProcessingEnabled, isLive: isLive,
                    baseColor: node.enabled ? palette.nodeSurface : palette.bypassedNodeSurface,
                    isExpanded: false, headerHeight: nodeHeaderHeight)
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

                    let initialPointerY = currentMouseYInRackSpace() ?? (origin.y + nodeHeaderHeight / 2)
                    dragPointerYOffset = initialPointerY - origin.y

                    // The floating card first appears at rest, then lifts on
                    // the next turn so the change is animated.
                    Task { @MainActor in
                        if draggingNodeID == nodeID, !isFinishingDrag { isLifted = true }
                    }
                }
                guard draggingNodeID == nodeID else { return }

                // The launch position is captured once, before any rows move.
                // Snapshot thresholds also prevent animated layout feedback.
                if let mouseY = currentMouseYInRackSpace() {
                    dragFloatingY = mouseY - dragPointerYOffset
                } else {
                    dragFloatingY = dragOrigin.y + gesture.translation.height
                }
                dragFloatingX = max(
                    -dragHorizontalLimit,
                    min(dragHorizontalLimit, gesture.translation.width * dragHorizontalDamping)
                )
                let centerY = dragFloatingY + nodeHeaderHeight / 2
                updateDragTarget(forCenterY: centerY)
                updateAutoScroll(forCenterY: centerY)
            }
            .onEnded { gesture in
                guard draggingNodeID == nodeID, let order = dragNodeOrder else { return }
                isFinishingDrag = true
                stopAutoScroll()
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
                    // The wires reconnected at release; this only hands the
                    // landed card back to its row.
                    cancelDrag()
                }
            }
    }

    private func cancelDrag() {
        stopAutoScroll()
        dragCleanupTask?.cancel()
        dragCleanupTask = nil
        draggingNodeID = nil
        dragNodeOrder = nil
        dragRowFrames = [:]
        isFinishingDrag = false
        isLifted = false
        dragFloatingX = 0
        dragFloatingY = 0
        dragPointerYOffset = 0
    }

    private func updateDragTarget(forCenterY centerY: CGFloat) {
        guard let nodeID = draggingNodeID, var order = dragNodeOrder else { return }
        let target = nodes.filter { node in
            node.nodeID != nodeID
                && centerY > (dragRowFrames[node.nodeID]?.minY ?? .infinity) + nodeHeaderHeight / 2
        }.count
        guard let current = order.firstIndex(of: nodeID), current != target else { return }
        order.remove(at: current)
        order.insert(nodeID, at: min(target, order.count))
        withAnimation(reorderAnimation) { dragNodeOrder = order }
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
            let viewport = visibleViewportInRackSpace(),
            let scrollBounds = autoScrollOriginBounds()
        else { return 0 }

        let canScrollUp = scrollBounds.originY > scrollBounds.minY + 0.5
        let canScrollDown = scrollBounds.originY < scrollBounds.maxY - 0.5

        let pointerY = currentMouseYInRackSpace() ?? centerY
        let topReferenceY = min(pointerY, dragFloatingY)
        let bottomReferenceY = max(pointerY, dragFloatingY + nodeHeaderHeight)

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
        guard draggingNodeID != nil, abs(autoScrollVelocity) > 0.5 else {
            stopAutoScroll()
            return
        }

        let delta = scrollEnclosingScrollView(by: autoScrollVelocity / 60)
        guard abs(delta) > 0.05 else {
            stopAutoScroll()
            return
        }

        if let mouseY = currentMouseYInRackSpace() {
            dragFloatingY = mouseY - dragPointerYOffset
        }
        let centerY = dragFloatingY + nodeHeaderHeight / 2
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
        let minY: CGFloat = 0
        guard delta >= 0 || oldOrigin.y > minY + 0.05 else { return 0 }
        guard delta <= 0 || oldOrigin.y < maxY - 0.05 else { return 0 }
        let newY = max(minY, min(maxY, oldOrigin.y + delta))
        guard abs(newY - oldOrigin.y) > 0.05 else { return 0 }

        clipView.scroll(to: NSPoint(x: oldOrigin.x, y: newY))
        scrollView.reflectScrolledClipView(clipView)
        return newY - oldOrigin.y
    }

    private func visibleViewportInRackSpace() -> CGRect? {
        guard
            let scrollView = enclosingScrollView,
            let documentView = scrollView.documentView,
            let coordinateView = rackCoordinateView,
            coordinateView.window != nil
        else { return nil }

        let viewport = coordinateView
            .convert(scrollView.contentView.documentVisibleRect, from: documentView)
            .standardized
        guard !viewport.isNull, viewport.height > 0 else { return nil }
        return viewport
    }

    private func autoScrollOriginBounds() -> (originY: CGFloat, minY: CGFloat, maxY: CGFloat)? {
        guard
            let scrollView = enclosingScrollView,
            let documentView = scrollView.documentView
        else { return nil }

        let clipView = scrollView.contentView
        let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
        let minY: CGFloat = 0
        return (clipView.bounds.origin.y, minY, maxY)
    }

    private func currentMouseYInRackSpace() -> CGFloat? {
        guard
            let coordinateView = rackCoordinateView,
            let window = coordinateView.window
        else { return nil }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return coordinateView.convert(windowPoint, from: nil).y
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
            }
            Section("低音") {
                addButton(.classicBass())
                addButton(.effect(DSPHybridBassParameters()))
            }
            Section("空间") {
                addButton(.stereoWidth())
                addButton(.effect(DSPCrossfeedParameters()))
                addButton(.effect(DSPSpatialAudioParameters()))
                addButton(.effect(DSPReverbParameters()))
            }
            Section("音色与动态") {
                addButton(.tube())
                addButton(.effect(DSPCompressorParameters()))
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
        case DSPNodeConfiguration.classicBassTypeID: "speaker.wave.1"
        case DSPNodeConfiguration.hybridBassTypeID: "speaker.wave.3"
        case DSPNodeConfiguration.stereoWidthTypeID: "arrow.left.and.right"
        case DSPNodeConfiguration.crossfeedTypeID: "arrow.triangle.swap"
        case DSPNodeConfiguration.spatialAudioTypeID: "person.wave.2"
        case DSPNodeConfiguration.reverbTypeID: "dot.radiowaves.left.and.right"
        case DSPNodeConfiguration.tubeTypeID: "dial.low"
        case DSPNodeConfiguration.compressorTypeID: "gauge.with.dots.needle.33percent"
        case DSPNodeConfiguration.scriptTypeID: "curlybraces"
        default: "questionmark.square.dashed"
        }
    }

    static func title(for typeID: String) -> String {
        DSPNodeConfiguration.displayTitle(forTypeID: typeID)
    }

    /// Summaries use the same precision and units as the node's own controls.
    static func summary(for node: DSPNodeConfiguration) -> String {
        switch node.typeID {
        case DSPNodeConfiguration.parametricEQTypeID:
            let count = node.parametricEQBands?.filter(\.enabled).count ?? 0
            return "\(count) 个频段"
        case DSPNodeConfiguration.classicBassTypeID:
            return node.effectParameters(DSPClassicBassParameters.self).map {
                "\(targetTitle($0.target))，低音 \(format($0.bassGainDB, digits: 1)) dB，虚拟 \(format($0.intensity * 100, digits: 0))%"
            } ?? ""
        case DSPNodeConfiguration.hybridBassTypeID:
            return node.effectParameters(DSPHybridBassParameters.self).map {
                "\(targetTitle($0.target))，低音 \(format($0.bassGainDB, digits: 1)) dB，虚拟 \(format($0.intensity * 100, digits: 0))%"
            } ?? ""
        case DSPNodeConfiguration.stereoWidthTypeID:
            return node.stereoWidthParameters.map { "宽度 \(format($0.width, digits: 2))×" } ?? ""
        case DSPNodeConfiguration.crossfeedTypeID:
            return node.effectParameters(DSPCrossfeedParameters.self).map {
                switch $0.strength {
                case .light: "轻"
                case .medium: "中"
                case .strong: "重"
                }
            } ?? ""
        case DSPNodeConfiguration.spatialAudioTypeID:
            return node.effectParameters(DSPSpatialAudioParameters.self).map { parameters in
                switch parameters.source {
                case .impulseResponse:
                    parameters.impulseResponseName.isEmpty ? "脉冲响应" : parameters.impulseResponseName
                case .room:
                    "虚拟音箱 · \(format(parameters.distanceM, digits: 1)) m"
                }
            } ?? ""
        case DSPNodeConfiguration.reverbTypeID:
            return node.effectParameters(DSPReverbParameters.self).map {
                "\(spaceTitle($0.space)) · 混合 \(format($0.mix, digits: 2))"
            } ?? ""
        case DSPNodeConfiguration.tubeTypeID:
            return node.tubeParameters.map {
                $0.mode == .hifi
                    ? "高保真 · 强度 \(format($0.hifiAmount, digits: 2))"
                    : "驱动 \(format($0.driveDB, digits: 1)) dB"
            } ?? ""
        case DSPNodeConfiguration.compressorTypeID:
            return node.effectParameters(DSPCompressorParameters.self).map {
                switch $0.style {
                case .gentle: "轻柔"
                case .night: "夜间"
                case .custom: "自定义"
                }
            } ?? ""
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

    private static func targetTitle(_ target: DSPBassTarget) -> String {
        switch target {
        case .automatic: "自动"
        case .headphones: "耳机"
        case .speakers: "扬声器"
        }
    }

    private static func spaceTitle(_ space: DSPReverbSpace) -> String {
        switch space {
        case .room: "房间"
        case .studio: "录音棚"
        case .plate: "板式"
        case .hall: "大厅"
        }
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

// MARK: - Rack Scroll View Resolver

private struct DSPRackScrollViewResolver: NSViewRepresentable {
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
                onResolve?(enclosingScrollView, self)
            }
        }
    }
}

private struct DSPLimiterWarningIndicator: View {
    let reductionDB: Float

    @State private var isPopoverPresented = false
    @State private var isAnchorHovered = false
    @State private var isPopoverHovered = false
    @State private var dismissTask: Task<Void, Never>?

    private var measuredReduction: String {
        max(0, reductionDB).formatted(.number.precision(.fractionLength(1)))
    }

    private var recommendedReduction: String {
        let roundedUp = (max(0.05, Double(reductionDB)) * 2).rounded(.up) / 2
        return max(0.5, roundedUp).formatted(.number.precision(.fractionLength(1)))
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.red)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("安全限幅提示")
        .accessibilityValue("建议将输入增益降低约 \(recommendedReduction) dB")
        .onHover(perform: anchorHoverChanged)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("安全限幅")
                    .font(.system(size: 14, weight: .semibold))
                Text("最近限幅约 \(measuredReduction) dB")
                    .font(.system(size: 13))
                Text("建议将输入增益降低约 \(recommendedReduction) dB")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(14)
            .frame(width: 288, alignment: .leading)
            .appPopupAppearance(style: .appTip)
            .onHover(perform: popoverHoverChanged)
        }
    }

    private func anchorHoverChanged(_ hovering: Bool) {
        isAnchorHovered = hovering
        if hovering {
            dismissTask?.cancel()
            isPopoverPresented = true
        } else {
            scheduleDismiss()
        }
    }

    private func popoverHoverChanged(_ hovering: Bool) {
        isPopoverHovered = hovering
        if hovering {
            dismissTask?.cancel()
        } else {
            scheduleDismiss()
        }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            if !isAnchorHovered && !isPopoverHovered {
                isPopoverPresented = false
            }
        }
    }
}
