import SwiftUI

@MainActor
struct AudioDSPNativeEffectsNodeCard: View {
    let node: DSPNodeConfiguration
    let index: Int
    let nodeCount: Int
    @Binding var isExpanded: Bool
    let onEnabledChange: @MainActor @Sendable (Bool) -> Void
    let onChannelPolicyChange: @MainActor @Sendable (String) -> Void
    let onQualityChange: @MainActor @Sendable (String) -> Void
    let onStereoWidthParametersChange: (DSPStereoWidthParameters) -> Void
    let onVirtualBassParametersChange: (DSPVirtualBassParameters) -> Void
    let onTubeParametersChange: (DSPTubeParameters) -> Void
    let onCommit: () -> Void
    let onMove: (Int) -> Void
    let onRemove: () -> Void

    private var title: String {
        switch node.typeID {
        case DSPNodeConfiguration.stereoWidthTypeID: "立体声扩展"
        case DSPNodeConfiguration.virtualBassTypeID: "虚拟低音"
        case DSPNodeConfiguration.tubeTypeID: "电子管模拟"
        default: "音频效果"
        }
    }

    private var policies: [String] {
        let allowed = DSPNodeConfiguration.supportedChannelPolicies(forTypeID: node.typeID)
        let order = ["fullRange", "frontPair", "allChannels"]
        return order.filter(allowed.contains)
    }

    private var qualities: [String] {
        let allowed = DSPNodeConfiguration.supportedQualities(forTypeID: node.typeID)
        let order = [
            DSPNodeConfiguration.standardQuality,
            DSPNodeConfiguration.oversampling2xQuality,
            DSPNodeConfiguration.oversampling4xQuality,
        ]
        return order.filter(allowed.contains)
    }

    var body: some View {
        SettingsSection("\(title) \(index + 1)") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSwitchRow(
                    title: "启用\(title)",
                    isOn: Binding(get: { node.enabled }, set: onEnabledChange)
                )

                HStack(spacing: 8) {
                    CapsulePicker(
                        label: "声道范围",
                        options: policies,
                        selection: channelPolicyBinding,
                        displayName: policyTitle
                    )

                    if qualities.count > 1 || !qualities.contains(node.quality) {
                        CapsulePicker(
                            label: "质量",
                            options: qualities,
                            selection: qualityBinding,
                            displayName: qualityTitle
                        )
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button {
                        onMove(-1)
                    } label: {
                        Label("上移", systemImage: "chevron.up")
                            .labelStyle(.iconOnly)
                    }
                    .dspIconButtonStyle()
                    .accessibilityLabel("上移\(title)")
                    .disabled(index == 0)

                    Button {
                        onMove(1)
                    } label: {
                        Label("下移", systemImage: "chevron.down")
                            .labelStyle(.iconOnly)
                    }
                    .dspIconButtonStyle()
                    .accessibilityLabel("下移\(title)")
                    .disabled(index == nodeCount - 1)

                    Button(role: .destructive, action: onRemove) {
                        Label("移除", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .dspIconButtonStyle()
                    .accessibilityLabel("移除\(title)")
                }

                DisclosureGroup("参数", isExpanded: $isExpanded) {
                    parameterControls
                        .padding(.top, 10)
                }
            }
        }
    }

    @ViewBuilder
    private var parameterControls: some View {
        switch node.typeID {
        case DSPNodeConfiguration.stereoWidthTypeID:
            stereoWidthControls
        case DSPNodeConfiguration.virtualBassTypeID:
            virtualBassControls
        case DSPNodeConfiguration.tubeTypeID:
            tubeControls
        default:
            Text("效果参数无法读取。")
                .settingsDescriptionStyle()
        }
    }

    private var stereoWidthControls: some View {
        return VStack(alignment: .leading, spacing: 12) {
            DSPRangeSliderRow(
                title: "立体声宽度",
                value: stereoWidthBinding(\.width),
                range: DSPStereoWidthParameters.widthRange,
                step: 0.01,
                unit: "×",
                onCommit: onCommit
            )
            DSPRangeSliderRow(
                title: "输出增益",
                value: stereoWidthBinding(\.outputTrimDB),
                range: DSPStereoWidthParameters.outputTrimRange,
                step: 0.1,
                onCommit: onCommit
            )
        }
    }

    private var virtualBassControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            DSPRangeSliderRow(
                title: "频带下限",
                value: virtualBassBinding(\.lowFrequencyHz),
                range: DSPVirtualBassParameters.lowFrequencyRange,
                step: 1,
                unit: "Hz",
                onCommit: onCommit
            )
            DSPRangeSliderRow(
                title: "频带上限",
                value: virtualBassBinding(\.highFrequencyHz),
                range: DSPVirtualBassParameters.highFrequencyRange,
                step: 1,
                unit: "Hz",
                onCommit: onCommit
            )
            DSPRangeSliderRow(
                title: "低频强度",
                value: virtualBassBinding(\.amount),
                range: DSPVirtualBassParameters.amountRange,
                step: 0.01,
                unit: "",
                onCommit: onCommit
            )
            DSPRangeSliderRow(
                title: "驱动",
                value: virtualBassBinding(\.driveDB),
                range: DSPVirtualBassParameters.driveRange,
                step: 0.1,
                onCommit: onCommit
            )
            DSPRangeSliderRow(
                title: "谐波倾向（0 偶次，1 奇次）",
                value: virtualBassBinding(\.harmonics),
                range: DSPVirtualBassParameters.harmonicsRange,
                step: 0.01,
                unit: "",
                onCommit: onCommit
            )
            DSPRangeSliderRow(
                title: "混合",
                value: virtualBassBinding(\.mix),
                range: DSPVirtualBassParameters.mixRange,
                step: 0.01,
                unit: "",
                onCommit: onCommit
            )
            DSPRangeSliderRow(
                title: "输出增益",
                value: virtualBassBinding(\.outputTrimDB),
                range: DSPVirtualBassParameters.outputTrimRange,
                step: 0.1,
                onCommit: onCommit
            )
            .disabled((node.virtualBassParameters ?? DSPVirtualBassParameters()).mix == 0)
        }
    }

    private var tubeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            DSPRangeSliderRow(
                title: "驱动",
                value: tubeBinding(\.driveDB),
                range: DSPTubeParameters.driveRange,
                step: 0.1,
                onCommit: onCommit
            )
            DSPRangeSliderRow(
                title: "偏置",
                value: tubeBinding(\.bias),
                range: DSPTubeParameters.biasRange,
                step: 0.01,
                unit: "",
                onCommit: onCommit
            )
            DSPRangeSliderRow(
                title: "混合",
                value: tubeBinding(\.mix),
                range: DSPTubeParameters.mixRange,
                step: 0.01,
                unit: "",
                onCommit: onCommit
            )
            DSPRangeSliderRow(
                title: "输入增益",
                value: tubeBinding(\.inputTrimDB),
                range: DSPTubeParameters.inputTrimRange,
                step: 0.1,
                onCommit: onCommit
            )
            .disabled((node.tubeParameters ?? DSPTubeParameters()).mix == 0)

            DSPRangeSliderRow(
                title: "输出增益",
                value: tubeBinding(\.outputTrimDB),
                range: DSPTubeParameters.outputTrimRange,
                step: 0.1,
                onCommit: onCommit
            )
            .disabled((node.tubeParameters ?? DSPTubeParameters()).mix == 0)

            SettingsSwitchRow(
                title: "直流移除",
                isOn: tubeDCRemovalBinding
            )
            .disabled((node.tubeParameters ?? DSPTubeParameters()).mix == 0)

            DSPRangeSliderRow(
                title: "直流阻隔频率",
                value: tubeBinding(\.dcBlockHz),
                range: DSPTubeParameters.dcBlockFrequencyRange,
                step: 1,
                unit: "Hz",
                onCommit: onCommit
            )
            .disabled((node.tubeParameters ?? DSPTubeParameters()).mix == 0
                || !(node.tubeParameters ?? DSPTubeParameters()).dcRemovalEnabled)
        }
    }

    private var channelPolicyBinding: Binding<String> {
        Binding(get: { node.channelPolicy }, set: onChannelPolicyChange)
    }

    private var qualityBinding: Binding<String> {
        Binding(get: { node.quality }, set: onQualityChange)
    }

    private var tubeDCRemovalBinding: Binding<Bool> {
        Binding(
            get: { (node.tubeParameters ?? DSPTubeParameters()).dcRemovalEnabled },
            set: { value in
                var parameters = node.tubeParameters ?? DSPTubeParameters()
                parameters.dcRemovalEnabled = value
                onTubeParametersChange(parameters)
            }
        )
    }

    private func stereoWidthBinding(
        _ keyPath: WritableKeyPath<DSPStereoWidthParameters, Double>
    ) -> Binding<Double> {
        Binding(
            get: { (node.stereoWidthParameters ?? DSPStereoWidthParameters())[keyPath: keyPath] },
            set: { value in
                var parameters = node.stereoWidthParameters ?? DSPStereoWidthParameters()
                parameters[keyPath: keyPath] = value
                onStereoWidthParametersChange(parameters)
            }
        )
    }

    private func virtualBassBinding(
        _ keyPath: WritableKeyPath<DSPVirtualBassParameters, Double>
    ) -> Binding<Double> {
        Binding(
            get: { (node.virtualBassParameters ?? DSPVirtualBassParameters())[keyPath: keyPath] },
            set: { value in
                var parameters = node.virtualBassParameters ?? DSPVirtualBassParameters()
                parameters[keyPath: keyPath] = value
                onVirtualBassParametersChange(parameters)
            }
        )
    }

    private func tubeBinding(
        _ keyPath: WritableKeyPath<DSPTubeParameters, Double>
    ) -> Binding<Double> {
        Binding(
            get: { (node.tubeParameters ?? DSPTubeParameters())[keyPath: keyPath] },
            set: { value in
                var parameters = node.tubeParameters ?? DSPTubeParameters()
                parameters[keyPath: keyPath] = value
                onTubeParametersChange(parameters)
            }
        )
    }

    private func policyTitle(_ policy: String) -> String {
        switch policy {
        case "fullRange": "全频声道"
        case "frontPair": "前置左右声道"
        case "allChannels": "所有声道"
        default: policy
        }
    }

    private func qualityTitle(_ quality: String) -> String {
        switch quality {
        case DSPNodeConfiguration.standardQuality: "标准"
        case DSPNodeConfiguration.oversampling2xQuality: "2× 过采样"
        case DSPNodeConfiguration.oversampling4xQuality: "4× 过采样"
        default: quality
        }
    }
}
