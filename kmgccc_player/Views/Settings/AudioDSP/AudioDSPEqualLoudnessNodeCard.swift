import SwiftUI

@MainActor
struct AudioDSPEqualLoudnessNodeCard: View {
    let node: DSPNodeConfiguration
    let index: Int
    let nodeCount: Int
    let context: DSPEqualLoudnessContext
    let sampleRate: Double
    @Binding var isExpanded: Bool
    let onEnabledChange: @MainActor @Sendable (Bool) -> Void
    let onChannelPolicyChange: @MainActor @Sendable (String) -> Void
    let onParametersChange: (DSPEqualLoudnessParameters) -> Void
    let onCommit: () -> Void
    let onMove: (Int) -> Void
    let onRemove: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    private var parameters: DSPEqualLoudnessParameters? {
        node.equalLoudnessParameters
    }

    private var currentGains: DSPEqualLoudnessGains {
        DSPEqualLoudnessMath.gains(node: node, context: context)
    }

    var body: some View {
        SettingsSection("等响补偿 \(index + 1)") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSwitchRow(
                    title: "启用等响补偿",
                    isOn: Binding(get: { node.enabled }, set: onEnabledChange)
                )

                HStack(spacing: 8) {
                    Picker("声道范围", selection: channelPolicyBinding) {
                        Text("全频声道，保留 LFE").tag("fullRange")
                        Text("所有声道").tag("allChannels")
                    }
                    .pickerStyle(.menu)

                    Spacer(minLength: 0)

                    Button {
                        onMove(-1)
                    } label: {
                        Label("上移", systemImage: "chevron.up")
                            .labelStyle(.iconOnly)
                    }
                    .dspIconButtonStyle()
                    .accessibilityLabel("上移等响补偿")
                    .disabled(index == 0)

                    Button {
                        onMove(1)
                    } label: {
                        Label("下移", systemImage: "chevron.down")
                            .labelStyle(.iconOnly)
                    }
                    .dspIconButtonStyle()
                    .accessibilityLabel("下移等响补偿")
                    .disabled(index == nodeCount - 1)

                    Button(role: .destructive, action: onRemove) {
                        Label("移除", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .dspIconButtonStyle()
                    .accessibilityLabel("移除等响补偿")
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(context.referenceDB == nil ? "相对补偿" : "设备参考")
                        .settingsRowLabelStyle()
                    Spacer(minLength: 4)
                    Text("低频 +\(currentGains.bassDB.formatted(.number.precision(.fractionLength(1)))) · 高频 +\(currentGains.trebleDB.formatted(.number.precision(.fractionLength(1)))) dB")
                        .font(.caption.monospacedDigit())
                        .settingsDescriptionStyle()
                }

                AudioDSPEqualLoudnessResponseCurve(
                    node: node,
                    context: context,
                    sampleRate: sampleRate,
                    accentColor: themeStore.accentColor
                )

                DisclosureGroup("补偿参数", isExpanded: $isExpanded) {
                    if parameters != nil {
                        VStack(alignment: .leading, spacing: 12) {
                            DSPRangeSliderRow(
                                title: "强度",
                                value: parameterBinding(\.strength),
                                range: DSPEqualLoudnessParameters.strengthRange,
                                step: 0.01,
                                unit: "",
                                onCommit: onCommit
                            )
                            DSPRangeSliderRow(
                                title: "最大低频补偿",
                                value: parameterBinding(\.maxBassGainDB),
                                range: DSPEqualLoudnessParameters.maxBassGainRange,
                                step: 0.1,
                                onCommit: onCommit
                            )
                            DSPRangeSliderRow(
                                title: "最大高频补偿",
                                value: parameterBinding(\.maxTrebleGainDB),
                                range: DSPEqualLoudnessParameters.maxTrebleGainRange,
                                step: 0.1,
                                onCommit: onCommit
                            )
                            DSPRangeSliderRow(
                                title: "低架频率",
                                value: parameterBinding(\.bassFrequencyHz),
                                range: DSPEqualLoudnessParameters.bassFrequencyRange,
                                step: 1,
                                unit: "Hz",
                                onCommit: onCommit
                            )
                            DSPRangeSliderRow(
                                title: "低架斜率 S",
                                value: parameterBinding(\.bassQ),
                                range: DSPEqualLoudnessParameters.shelfSlopeRange,
                                step: 0.01,
                                unit: "S",
                                onCommit: onCommit
                            )
                            DSPRangeSliderRow(
                                title: "高架频率",
                                value: parameterBinding(\.trebleFrequencyHz),
                                range: DSPEqualLoudnessParameters.trebleFrequencyRange,
                                step: 100,
                                unit: "Hz",
                                onCommit: onCommit
                            )
                            DSPRangeSliderRow(
                                title: "高架斜率 S",
                                value: parameterBinding(\.trebleQ),
                                range: DSPEqualLoudnessParameters.shelfSlopeRange,
                                step: 0.01,
                                unit: "S",
                                onCommit: onCommit
                            )
                            DSPRangeSliderRow(
                                title: "补偿窗口",
                                value: parameterBinding(\.compensationWindowDB),
                                range: DSPEqualLoudnessParameters.compensationWindowRange,
                                step: 1,
                                onCommit: onCommit
                            )

                            Picker("余量参与", selection: headroomModeBinding) {
                                Text("自动余量").tag(DSPHeadroomMode.automatic)
                                Text("不计入余量").tag(DSPHeadroomMode.off)
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.top, 10)
                    } else {
                        Text("等响补偿参数无法读取。")
                            .settingsDescriptionStyle()
                            .padding(.top, 8)
                    }
                }
            }
        }
    }

    private var channelPolicyBinding: Binding<String> {
        Binding(get: { node.channelPolicy }, set: onChannelPolicyChange)
    }

    private var headroomModeBinding: Binding<DSPHeadroomMode> {
        Binding(
            get: { node.equalLoudnessParameters?.headroomMode ?? .automatic },
            set: { mode in
                var updated = node.equalLoudnessParameters ?? DSPEqualLoudnessParameters()
                updated.headroomMode = mode
                onParametersChange(updated)
                onCommit()
            }
        )
    }

    private func parameterBinding<Value>(
        _ keyPath: WritableKeyPath<DSPEqualLoudnessParameters, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                (node.equalLoudnessParameters ?? DSPEqualLoudnessParameters())[keyPath: keyPath]
            },
            set: { value in
                var updated = node.equalLoudnessParameters ?? DSPEqualLoudnessParameters()
                updated[keyPath: keyPath] = value
                onParametersChange(updated)
            }
        )
    }
}

private struct AudioDSPEqualLoudnessResponseCurve: View {
    let node: DSPNodeConfiguration
    let context: DSPEqualLoudnessContext
    let sampleRate: Double
    let accentColor: Color

    private let dbSpan = 12.0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("当前补偿曲线")
                .settingsDescriptionStyle()
            GeometryReader { geometry in
                let plot = CGRect(
                    x: 4,
                    y: 4,
                    width: max(1, geometry.size.width - 8),
                    height: max(1, geometry.size.height - 8)
                )
                Canvas { canvas, _ in
                    drawGrid(in: &canvas, plot: plot)
                    drawResponse(in: &canvas, plot: plot)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("等响补偿频率响应曲线")
                .accessibilityValue(curveAccessibilityValue)
            }
            .frame(height: 96)
        }
    }

    private var curveAccessibilityValue: String {
        let gains = DSPEqualLoudnessMath.gains(node: node, context: context)
        return "低频补偿 \(gains.bassDB.formatted(.number.precision(.fractionLength(1)))) dB，高频补偿 \(gains.trebleDB.formatted(.number.precision(.fractionLength(1)))) dB"
    }

    private func drawGrid(in context: inout GraphicsContext, plot: CGRect) {
        for value in stride(from: -12.0, through: 12.0, by: 6.0) {
            let y = plot.midY - plot.height * CGFloat(value / (dbSpan * 2))
            let line = Path(CGRect(x: plot.minX, y: y, width: plot.width, height: 0.6))
            context.fill(line, with: .color(.secondary.opacity(value == 0 ? 0.45 : 0.18)))
        }
    }

    private func drawResponse(in canvas: inout GraphicsContext, plot: CGRect) {
        guard sampleRate.isFinite, sampleRate > 0 else { return }
        let highFrequency = min(20_000, sampleRate * 0.49)
        let lowLog = log10(20.0)
        let highLog = log10(max(20.1, highFrequency))
        let pointCount = max(80, Int(plot.width))
        var path = Path()
        for index in 0...pointCount {
            let position = Double(index) / Double(pointCount)
            let frequency = pow(10, lowLog + (highLog - lowLog) * position)
            let response = DSPEqualLoudnessMath.responseDB(
                node: node,
                context: context,
                at: frequency,
                sampleRate: sampleRate
            )
            let x = plot.minX + plot.width * CGFloat(position)
            let boundedResponse = min(dbSpan, max(-dbSpan, response))
            let y = plot.midY - plot.height * CGFloat(boundedResponse / (dbSpan * 2))
            let point = CGPoint(x: x, y: y)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        let responseLine = path.strokedPath(
            StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
        )
        canvas.fill(responseLine, with: .color(accentColor))
    }
}
