//
//  AudioDSPNativeEffectEditors.swift
//  myPlayer2
//
//  Card contents of the native effects. Each card shows its picture first,
//  then two to four key controls: mode, main amount, one or two defining
//  traits. Parameters a mode or main control implies stay hidden here and
//  remain available through the automation schema.
//

import SwiftUI
import UniformTypeIdentifiers

struct AudioDSPNativeEffectEditor: View {
    let node: DSPNodeConfiguration
    /// The node is enabled and the chain is processing live audio.
    let isProcessing: Bool
    let outputKind: DSPOutputKind?
    let onUpdateNode: (UUID, (inout DSPNodeConfiguration) -> Void) -> Void
    let onCommit: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isImportingImpulseResponse = false
    @State private var isReadingImpulseResponse = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch node.typeID {
            case DSPNodeConfiguration.classicBassTypeID:
                readable(DSPClassicBassParameters.self) { classicBassEditor($0) }
            case DSPNodeConfiguration.hybridBassTypeID:
                readable(DSPHybridBassParameters.self) { hybridBassEditor($0) }
            case DSPNodeConfiguration.stereoWidthTypeID:
                readable(DSPStereoWidthParameters.self) { _ in stereoWidthEditor }
            case DSPNodeConfiguration.crossfeedTypeID:
                readable(DSPCrossfeedParameters.self) { crossfeedEditor($0) }
            case DSPNodeConfiguration.spatialAudioTypeID:
                readable(DSPSpatialAudioParameters.self) { spatialEditor($0) }
            case DSPNodeConfiguration.reverbTypeID:
                readable(DSPReverbParameters.self) { reverbEditor($0) }
            case DSPNodeConfiguration.tubeTypeID:
                readable(DSPTubeParameters.self) { tubeEditor($0) }
            case DSPNodeConfiguration.compressorTypeID:
                readable(DSPCompressorParameters.self) { compressorEditor($0) }
            default:
                unreadable
            }
        }
    }

    @ViewBuilder
    private func readable<P: DSPEffectParameterSet, Content: View>(
        _ type: P.Type,
        @ViewBuilder content: (P) -> Content
    ) -> some View {
        if let parameters = node.effectParameters(type) {
            content(parameters)
        } else {
            unreadable
        }
    }

    private var unreadable: some View {
        Text("参数无法读取。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Virtual bass

    private func classicBassEditor(_ parameters: DSPClassicBassParameters) -> some View {
        let resolved = parameters.resolved(for: outputKind)
        return Group {
            targetPicker(DSPClassicBassParameters.self, current: parameters.target) {
                $0.cutoffHz = 0
                $0.floorHz = 0
            }
            amountSlider("强度", DSPClassicBassParameters.self, \.intensity, range: DSPClassicBassParameters.intensityRange)
            DSPRangeSliderRow(
                title: "截止频率",
                value: automaticBinding(DSPClassicBassParameters.self, \.cutoffHz, resolved: resolved.cutoffHz),
                range: DSPClassicBassParameters.cutoffRange,
                step: 1,
                unit: "Hz",
                fractionDigits: 0,
                onCommit: onCommit
            )
            CapsulePicker(
                label: "音色",
                options: DSPBassCharacter.allCases,
                selection: choice(DSPClassicBassParameters.self, \.character),
                displayName: { $0 == .round ? "圆润" : "紧实" }
            )
        }
    }

    private func hybridBassEditor(_ parameters: DSPHybridBassParameters) -> some View {
        Group {
            targetPicker(DSPHybridBassParameters.self, current: parameters.target) { $0.cutoffHz = 0 }
            amountSlider("强度", DSPHybridBassParameters.self, \.intensity, range: DSPHybridBassParameters.intensityRange)
            DSPRangeSliderRow(
                title: "截止频率",
                value: automaticBinding(DSPHybridBassParameters.self, \.cutoffHz,
                                        resolved: parameters.resolvedCutoff(for: outputKind).cutoffHz),
                range: DSPHybridBassParameters.cutoffRange,
                step: 1,
                unit: "Hz",
                fractionDigits: 0,
                onCommit: onCommit
            )
            amountSlider("瞬态", DSPHybridBassParameters.self, \.transient, range: DSPHybridBassParameters.transientRange)
        }
    }

    /// Target picker for both bass nodes. A new target clears the frequencies
    /// that follow it, so they take the new target's values.
    private func targetPicker<P: DSPEffectParameterSet>(
        _ type: P.Type,
        current: DSPBassTarget,
        resetting reset: @escaping (inout P) -> Void
    ) -> some View where P: DSPBassTargeted {
        CapsulePicker(
            label: "目标",
            options: DSPBassTarget.allCases,
            selection: Binding(
                get: { current },
                set: { target in
                    guard target != current else { return }
                    update(type, commit: true) { parameters in
                        parameters.target = target
                        reset(&parameters)
                    }
                }
            ),
            displayName: { target in
                switch target {
                case .automatic: "自动"
                case .headphones: "耳机"
                case .speakers: "扬声器"
                }
            }
        )
    }

    // MARK: Stereo image

    private var stereoWidthEditor: some View {
        DSPRangeSliderRow(
            title: "宽度",
            value: binding(DSPStereoWidthParameters.self, \.width),
            range: DSPStereoWidthParameters.widthRange,
            step: 0.01,
            unit: "×",
            fractionDigits: 2,
            onCommit: onCommit
        )
    }

    private func crossfeedEditor(_ parameters: DSPCrossfeedParameters) -> some View {
        Group {
            CapsulePicker(
                label: "强度",
                options: DSPCrossfeedStrength.allCases,
                selection: Binding(
                    get: { parameters.strength },
                    set: { strength in
                        guard strength != parameters.strength else { return }
                        update(DSPCrossfeedParameters.self, commit: true) {
                            $0 = DSPCrossfeedParameters(strength: strength)
                        }
                    }
                ),
                displayName: { strength in
                    switch strength {
                    case .light: "轻"
                    case .medium: "中"
                    case .strong: "重"
                    }
                }
            )
            caption("耳机若已开启“空间化立体声”，两者会叠加。")
        }
    }

    // MARK: Spatial audio

    private func spatialEditor(_ parameters: DSPSpatialAudioParameters) -> some View {
        let missingResponse = parameters.source == .impulseResponse
            && !parameters.impulseResponseID.isEmpty
            && !DSPImpulseResponseStore.exists(id: parameters.impulseResponseID)
        // One container, so the file importer is attached once.
        return VStack(alignment: .leading, spacing: 10) {
            DSPSpatialRoom(parameters: parameters, isActive: isProcessing, accentColor: themeStore.accentColor)
                .frame(height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            CapsulePicker(
                label: "来源",
                options: DSPSpatialSource.allCases,
                selection: choice(DSPSpatialAudioParameters.self, \.source),
                displayName: { $0 == .room ? "虚拟音箱" : "脉冲响应" }
            )

            switch parameters.source {
            case .room:
                DSPRangeSliderRow(
                    title: "距离",
                    value: binding(DSPSpatialAudioParameters.self, \.distanceM),
                    range: DSPSpatialAudioParameters.distanceRange,
                    step: 0.1,
                    unit: "m",
                    onCommit: onCommit
                )
                DSPRangeSliderRow(
                    title: "音箱角度",
                    value: binding(DSPSpatialAudioParameters.self, \.speakerAngleDeg),
                    range: DSPSpatialAudioParameters.speakerAngleRange,
                    step: 1,
                    unit: "°",
                    fractionDigits: 0,
                    onCommit: onCommit
                )
            case .impulseResponse:
                impulseResponseRow(parameters)
                if missingResponse {
                    caption("找不到这个脉冲响应，请重新选择。")
                }
                if let importError {
                    caption(importError)
                }
                DSPRangeSliderRow(
                    title: "混合",
                    value: binding(DSPSpatialAudioParameters.self, \.mix),
                    range: DSPSpatialAudioParameters.mixRange,
                    step: 0.01,
                    unit: "",
                    fractionDigits: 2,
                    onCommit: onCommit
                )
            }

            if isProcessing {
                caption("系统空间音频已暂停")
            }
        }
        .fileImporter(
            isPresented: $isImportingImpulseResponse,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false,
            onCompletion: importImpulseResponse
        )
    }

    private func impulseResponseRow(_ parameters: DSPSpatialAudioParameters) -> some View {
        HStack(spacing: 12) {
            Text("文件")
                .settingsRowLabelStyle()
            Spacer(minLength: 8)
            Text(parameters.impulseResponseName.isEmpty ? "未选择" : parameters.impulseResponseName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(isReadingImpulseResponse ? "正在读取" : "选择") {
                importError = nil
                isImportingImpulseResponse = true
            }
            .audioDSPCapsuleButtonStyle()
            .disabled(isReadingImpulseResponse)
        }
    }

    private func importImpulseResponse(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let nodeID = node.nodeID
        isReadingImpulseResponse = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try DSPImpulseResponseStore.importFile(at: url) }
            }.value
            isReadingImpulseResponse = false
            switch outcome {
            case .success(let imported):
                onUpdateNode(nodeID) { candidate in
                    guard var parameters = candidate.effectParameters(DSPSpatialAudioParameters.self) else { return }
                    parameters.source = .impulseResponse
                    parameters.impulseResponseID = imported.id
                    parameters.impulseResponseName = imported.name
                    candidate.setEffectParameters(parameters)
                }
                onCommit()
            case .failure(let error):
                importError = (error as? LocalizedError)?.errorDescription ?? "无法读取这个音频文件。"
            }
        }
    }

    // MARK: Reverb

    private func reverbEditor(_ parameters: DSPReverbParameters) -> some View {
        Group {
            DSPReverbVisual(parameters: parameters, isActive: isProcessing)
                .frame(height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            CapsulePicker(
                label: "空间",
                options: DSPReverbSpace.allCases,
                selection: Binding(
                    get: { parameters.space },
                    set: { space in
                        guard space != parameters.space else { return }
                        update(DSPReverbParameters.self, commit: true) { current in
                            var next = DSPReverbParameters(space: space)
                            next.size = current.size
                            next.mix = current.mix
                            next.tone = current.tone
                            next.lowCutHz = current.lowCutHz
                            next.width = current.width
                            current = next
                        }
                    }
                ),
                displayName: { space in
                    switch space {
                    case .room: "房间"
                    case .studio: "录音棚"
                    case .plate: "板式"
                    case .hall: "大厅"
                    }
                }
            )
            amountSlider("大小", DSPReverbParameters.self, \.size, range: DSPReverbParameters.sizeRange)
            amountSlider("混合", DSPReverbParameters.self, \.mix, range: DSPReverbParameters.mixRange)
            amountSlider("明暗", DSPReverbParameters.self, \.tone, range: DSPReverbParameters.toneRange)
        }
    }

    // MARK: Tube

    private func tubeEditor(_ parameters: DSPTubeParameters) -> some View {
        let qualities = DSPNodeConfiguration.supportedQualities(forTypeID: node.typeID)
        return Group {
            CapsulePicker(
                label: "模式",
                options: DSPTubeMode.allCases,
                selection: choice(DSPTubeParameters.self, \.mode),
                displayName: { $0 == .classic ? "经典" : "高保真" }
            )
            if qualities.count > 1 {
                CapsulePicker(
                    label: "质量",
                    options: Array(qualities).sorted(by: DSPNodeDescriptor.qualityOrder),
                    selection: Binding(
                        get: { node.quality },
                        set: { quality in
                            guard quality != node.quality else { return }
                            onUpdateNode(node.nodeID) { $0.quality = quality }
                            onCommit()
                        }
                    ),
                    displayName: DSPNodeDescriptor.qualityTitle
                )
            }
            switch parameters.mode {
            case .classic:
                DSPRangeSliderRow(
                    title: "驱动",
                    value: binding(DSPTubeParameters.self, \.driveDB),
                    range: DSPTubeParameters.driveRange,
                    step: 0.1,
                    onCommit: onCommit
                )
                amountSlider("不对称", DSPTubeParameters.self, \.bias, range: DSPTubeParameters.biasRange)
                amountSlider("混合", DSPTubeParameters.self, \.mix, range: DSPTubeParameters.mixRange)
            case .hifi:
                amountSlider("强度", DSPTubeParameters.self, \.hifiAmount, range: DSPTubeParameters.hifiAmountRange)
            }
        }
    }

    // MARK: Compressor

    private func compressorEditor(_ parameters: DSPCompressorParameters) -> some View {
        Group {
            DSPCompressorMeter(
                nodeID: node.nodeID,
                lowCrossoverHz: parameters.lowCrossoverHz,
                highCrossoverHz: parameters.highCrossoverHz,
                isActive: isProcessing,
                accentColor: themeStore.accentColor,
                masterColor: themeStore.semanticPalette.complementaryAccentColor,
                onCrossoversChange: { low, high in
                    update(DSPCompressorParameters.self) { current in
                        current.lowCrossoverHz = low
                        current.highCrossoverHz = high
                    }
                },
                onCommit: onCommit
            )
            .frame(height: 64 + DSPCompressorMeterView.axisHeight)

            CapsulePicker(
                label: "风格",
                options: DSPCompressorStyle.allCases,
                selection: Binding(
                    get: { parameters.style },
                    set: { style in
                        guard style != parameters.style else { return }
                        update(DSPCompressorParameters.self, commit: true) { current in
                            current.style = style
                            if style != .custom { current.bands = style.bands }
                        }
                    }
                ),
                displayName: { style in
                    switch style {
                    case .gentle: "轻柔"
                    case .night: "夜间"
                    case .custom: "自定义"
                    }
                }
            )
            CapsulePicker(
                label: "速度",
                options: DSPCompressorSpeed.allCases,
                selection: choice(DSPCompressorParameters.self, \.speed),
                displayName: { speed in
                    switch speed {
                    case .fast: "快"
                    case .medium: "中"
                    case .slow: "慢"
                    }
                }
            )
            HStack(spacing: 6) {
                ForEach(Array(DSPCompressorBandKey.allCases.enumerated()), id: \.offset) { index, key in
                    compressorColumn(index: index, key: key, band: parameters.band(key))
                }
            }
        }
    }

    private func compressorColumn(index: Int, key: DSPCompressorBandKey, band: DSPCompressorBand) -> some View {
        let palette = DSPRackPalette(themeStore: themeStore, colorScheme: colorScheme)
        let title: String = switch key {
        case .low: "低"
        case .mid: "中"
        case .high: "高"
        case .master: "总"
        }
        return VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                // The master stage carries the complement, as in the graph.
                .foregroundStyle(key == .master
                    ? AnyShapeStyle(themeStore.semanticPalette.complementaryAccentColor)
                    : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            compressorField("阈值", title: title, index: index, keyPath: \.thresholdDB,
                            range: DSPCompressorBand.thresholdRange, step: 0.5, unit: "dB", digits: 1)
            compressorField("比率", title: title, index: index, keyPath: \.ratio,
                            range: DSPCompressorBand.ratioRange, step: 0.1, unit: "", digits: 1)
            compressorField("增益", title: title, index: index, keyPath: \.gainDB,
                            range: DSPCompressorBand.gainRange, step: 0.1, unit: "dB", digits: 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 5)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.bandSurface)
        )
    }

    private func compressorField(
        _ label: String,
        title: String,
        index: Int,
        keyPath: WritableKeyPath<DSPCompressorBand, Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String,
        digits: Int
    ) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrubbableNumberField(
                value: Binding(
                    get: {
                        let parameters = node.effectParameters(DSPCompressorParameters.self) ?? DSPCompressorParameters()
                        return parameters.bands.indices.contains(index) ? parameters.bands[index][keyPath: keyPath] : 0
                    },
                    set: { value in
                        update(DSPCompressorParameters.self) { current in
                            guard current.bands.indices.contains(index) else { return }
                            current.bands[index][keyPath: keyPath] = value
                            // Any hand edit makes the settings the listener's own.
                            current.style = .custom
                        }
                    }
                ),
                range: range,
                step: step,
                unit: unit,
                fractionDigits: digits,
                alignment: .center,
                onCommit: onCommit
            )
            .accessibilityLabel("\(title)\(label)")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Bindings

    private func update<P: DSPEffectParameterSet>(
        _ type: P.Type,
        commit: Bool = false,
        _ change: (inout P) -> Void
    ) {
        onUpdateNode(node.nodeID) { candidate in
            guard var parameters = candidate.effectParameters(type) else { return }
            change(&parameters)
            candidate.setEffectParameters(parameters)
        }
        if commit { onCommit() }
    }

    private func current<P: DSPEffectParameterSet>(_ type: P.Type) -> P {
        node.effectParameters(type) ?? P()
    }

    private func binding<P: DSPEffectParameterSet>(
        _ type: P.Type,
        _ keyPath: WritableKeyPath<P, Double>
    ) -> Binding<Double> {
        Binding(
            get: { current(type)[keyPath: keyPath] },
            set: { value in update(type) { $0[keyPath: keyPath] = value } }
        )
    }

    /// A frequency where 0 means "follow the target": the slider shows the
    /// value in use, and moving it stores an explicit one.
    private func automaticBinding<P: DSPEffectParameterSet>(
        _ type: P.Type,
        _ keyPath: WritableKeyPath<P, Double>,
        resolved: Double
    ) -> Binding<Double> {
        Binding(
            get: {
                let stored = current(type)[keyPath: keyPath]
                return stored == 0 ? resolved : stored
            },
            set: { value in update(type) { $0[keyPath: keyPath] = value } }
        )
    }

    private func choice<P: DSPEffectParameterSet, Value: Equatable>(
        _ type: P.Type,
        _ keyPath: WritableKeyPath<P, Value>
    ) -> Binding<Value> {
        Binding(
            get: { current(type)[keyPath: keyPath] },
            set: { value in
                guard value != current(type)[keyPath: keyPath] else { return }
                update(type, commit: true) { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func amountSlider<P: DSPEffectParameterSet>(
        _ title: String,
        _ type: P.Type,
        _ keyPath: WritableKeyPath<P, Double>,
        range: ClosedRange<Double>
    ) -> some View {
        DSPRangeSliderRow(
            title: title,
            value: binding(type, keyPath),
            range: range,
            step: 0.01,
            unit: "",
            fractionDigits: 2,
            onCommit: onCommit
        )
    }
}

/// Parameter sets tuned for a target transducer.
nonisolated protocol DSPBassTargeted {
    var target: DSPBassTarget { get set }
}

nonisolated extension DSPClassicBassParameters: DSPBassTargeted {}
nonisolated extension DSPHybridBassParameters: DSPBassTargeted {}
