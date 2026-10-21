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

struct AudioDSPNativeEffectEditor: View, Equatable {
    let node: DSPNodeConfiguration
    /// The node is enabled and the chain is processing live audio.
    let isProcessing: Bool
    let outputKind: DSPOutputKind?
    let onUpdateNode: (UUID, (inout DSPNodeConfiguration) -> Void) -> Void
    let onCommit: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsAppForegroundColors) private var appColors
    @State private var isImportingImpulseResponse = false
    @State private var isReadingImpulseResponse = false
    @State private var importError: String?

    /// Closures are left out, as in `AudioDSPEQEditor`: they route by node ID
    /// and always reach the same controller. Unrelated rack updates then skip
    /// this body, and the palette engine it calls.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.node == rhs.node && lhs.isProcessing == rhs.isProcessing && lhs.outputKind == rhs.outputKind
    }

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

    private static let mixInfo = "处理后的声音与原声的比例。"
    private static let bassCutoffInfo = "此频率以下的低音由谐波重新呈现。设备的低频越弱，可以设得越高。"

    private func classicBassEditor(_ parameters: DSPClassicBassParameters) -> some View {
        let intensityBinding = binding(DSPClassicBassParameters.self, \.intensity)
        return Group {
            targetPicker(DSPClassicBassParameters.self, current: parameters.target)
            DSPRangeSliderRow(
                title: "强度",
                value: Binding(get: { intensityBinding.wrappedValue * 100 }, set: { intensityBinding.wrappedValue = $0 / 100 }),
                range: 0...100,
                step: 1,
                unit: "%",
                fractionDigits: 0,
                onCommit: onCommit
            )
            DSPRangeSliderRow(
                title: "截止频率",
                value: binding(DSPClassicBassParameters.self, \.cutoffHz),
                range: DSPClassicBassParameters.cutoffRange,
                step: 1,
                unit: "Hz",
                fractionDigits: 0,
                info: Self.bassCutoffInfo,
                onCommit: onCommit
            )
            retainsRealBassRow(binding(DSPClassicBassParameters.self, \.retainsRealBass))
            DSPRangeSliderRow(
                title: "冲击",
                value: binding(DSPClassicBassParameters.self, \.impactDB),
                range: DSPClassicBassParameters.impactDBRange,
                step: 0.5,
                unit: "dB",
                fractionDigits: 1,
                info: "高次谐波的衰减程度。数值越高，泛音越丰富，低音轮廓越清晰，但可能引入杂讯。",
                onCommit: onCommit
            )
        }
    }

    private func hybridBassEditor(_ parameters: DSPHybridBassParameters) -> some View {
        let intensityBinding = binding(DSPHybridBassParameters.self, \.intensity)
        let impactBinding = binding(DSPHybridBassParameters.self, \.impact)
        return Group {
            targetPicker(DSPHybridBassParameters.self, current: parameters.target)
            DSPRangeSliderRow(
                title: "强度",
                value: Binding(get: { intensityBinding.wrappedValue * 100 }, set: { intensityBinding.wrappedValue = $0 / 100 }),
                range: 0...100,
                step: 1,
                unit: "%",
                fractionDigits: 0,
                onCommit: onCommit
            )
            DSPRangeSliderRow(
                title: "截止频率",
                value: binding(DSPHybridBassParameters.self, \.cutoffHz),
                range: DSPHybridBassParameters.cutoffRange,
                step: 1,
                unit: "Hz",
                fractionDigits: 0,
                info: Self.bassCutoffInfo,
                onCommit: onCommit
            )
            retainsRealBassRow(binding(DSPHybridBassParameters.self, \.retainsRealBass))
            DSPRangeSliderRow(
                title: "冲击",
                value: Binding(get: { impactBinding.wrappedValue * 100 }, set: { impactBinding.wrappedValue = $0 / 100 }),
                range: 0...100,
                step: 1,
                unit: "%",
                fractionDigits: 0,
                info: "生成谐波时的驱动力度。数值越高，低音越饱满有力，但可能引入杂讯。",
                onCommit: onCommit
            )
        }
    }

    /// Target picker for both bass nodes. Preserves and restores each target's settings.
    private func targetPicker<P: DSPEffectParameterSet>(
        _ type: P.Type,
        current: DSPBassTarget
    ) -> some View where P: DSPBassTargeted {
        CapsulePicker(
            label: "目标",
            options: DSPBassTarget.allCases,
            selection: Binding(
                get: { current },
                set: { target in
                    guard target != current else { return }
                    update(type, commit: true) { parameters in
                        parameters.switchTarget(to: target)
                    }
                }
            ),
            displayName: { target in
                switch target {
                case .automatic: "自动"
                case .headphones: "耳机"
                case .speakers: "扬声器"
                }
            },
            info: "按照你正在使用的设备选择，并重新调整到合适的参数。"
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
            info: "1.00× 为原始声场，低于此值收窄，高于此值展宽。",
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
                },
                info: "让两个声道产生一些混合，模拟音箱听感。"
            )
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
                displayName: { $0 == .room ? "虚拟音箱" : "脉冲响应" },
                info: "虚拟音箱在耳机中模拟面前的一对音箱；脉冲响应可导入实测空间的音频文件。"
            )

            switch parameters.source {
            case .room:
                CapsulePicker(
                    label: "房间",
                    options: DSPRoomPreset.allCases,
                    selection: choice(DSPSpatialAudioParameters.self, \.room),
                    displayName: { $0 == .none ? "无" : "录音室" }
                )
                if parameters.room != .none {
                    DSPRangeSliderRow(
                        title: "距离",
                        value: binding(DSPSpatialAudioParameters.self, \.distanceM),
                        range: DSPSpatialAudioParameters.distanceRange,
                        step: 0.1,
                        unit: "m",
                        onCommit: onCommit
                    )
                }
                DSPRangeSliderRow(
                    title: "音箱角度",
                    value: binding(DSPSpatialAudioParameters.self, \.speakerAngleDeg),
                    range: DSPSpatialAudioParameters.speakerAngleRange,
                    step: 1,
                    unit: "°",
                    fractionDigits: 0,
                    info: "每只音箱偏离正前方的角度。角度越大，声场越开阔。",
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
            }

            DSPRangeSliderRow(
                title: "混合",
                value: binding(DSPSpatialAudioParameters.self, \.mix),
                range: DSPSpatialAudioParameters.mixRange,
                step: 0.01,
                unit: "",
                fractionDigits: 2,
                info: Self.mixInfo,
                onCommit: onCommit
            )

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
            DSPReverbVisual(parameters: parameters, isActive: isProcessing,
                            palette: themeStore.artworkSwatchColors(count: 5))
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
            amountSlider("大小", DSPReverbParameters.self, \.size, range: DSPReverbParameters.sizeRange,
                         info: "空间越大，混响越悠长。")
            amountSlider("混合", DSPReverbParameters.self, \.mix, range: DSPReverbParameters.mixRange,
                         info: Self.mixInfo)
            amountSlider("明暗", DSPReverbParameters.self, \.tone, range: DSPReverbParameters.toneRange,
                         info: "调节混响中高频的比例。")
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
                displayName: { $0 == .classic ? "经典" : "高保真" },
                info: "经典让整段声音一同饱和，色彩浓郁；高保真只在原声之上叠加少量谐波，原声保持完整。"
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
                    info: "送入电子管的电平。数值越高，饱和越明显。",
                    onCommit: onCommit
                )
                amountSlider("不对称", DSPTubeParameters.self, \.bias, range: DSPTubeParameters.biasRange,
                             info: "偏离零点越远，偶次谐波越多，声音越温暖。")
                amountSlider("混合", DSPTubeParameters.self, \.mix, range: DSPTubeParameters.mixRange,
                             info: Self.mixInfo)
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
                        current.useCustomSettings()
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
                            current.selectStyle(style)
                        }
                    }
                ),
                displayName: { style in
                    switch style {
                    case .gentle: "轻柔"
                    case .night: "夜间"
                    case .custom: "自定义"
                    }
                },
                info: "轻柔使整体动态更平稳；夜间更明显地收住响亮的段落，适合低音量聆听细节。调整任一数值即转为自定义。"
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
            compressorSpeedPicker(index: index, band: band)
            HStack(spacing: 4) {
                compressorField("攻击", title: title, index: index, keyPath: \.attackMs,
                                range: DSPCompressorBand.attackRange, step: 0.1, unit: "ms", digits: 1)
                compressorField("释放", title: title, index: index, keyPath: \.releaseMs,
                                range: DSPCompressorBand.releaseRange, step: 1, unit: "ms", digits: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 5)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.bandSurface)
        )
    }

    private func compressorSpeedPicker(index: Int, band: DSPCompressorBand) -> some View {
        VStack(spacing: 2) {
            Text("速度")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(DSPCompressorSpeed.allCases, id: \.rawValue) { speed in
                        let isSelected = matchingSpeed(for: band) == speed
                        Button {
                            setCompressorSpeed(speed, index: index)
                        } label: {
                            Text(compressorSpeedTitle(speed))
                                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                                .foregroundStyle(isSelected ? themeStore.accentColor : (appColors?.secondary ?? .secondary))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .background {
                                    if isSelected {
                                        Capsule().fill(themeStore.accentColor.opacity(0.18))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(compressorSpeedTitle(speed))速")
                    }
                }
                .padding(3)
                .background(Capsule().fill((appColors?.secondary ?? .secondary).opacity(0.08)))
                .contentShape(Capsule())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onEnded { value in
                            let segmentWidth = max(1, (proxy.size.width - 6) / 3)
                            let selectedIndex = min(2, max(0, Int((value.location.x - 3) / segmentWidth)))
                            setCompressorSpeed(DSPCompressorSpeed.allCases[selectedIndex], index: index)
                        }
                )
            }
            .frame(height: 27)
        }
        .frame(maxWidth: .infinity)
        // Custom timings dim the selector without disabling taps or dragging.
        .opacity(matchingSpeed(for: band) == nil ? 0.55 : 1)
    }

    private func setCompressorSpeed(_ speed: DSPCompressorSpeed, index: Int) {
        let parameters = current(DSPCompressorParameters.self)
        guard parameters.bands.indices.contains(index),
              matchingSpeed(for: parameters.bands[index]) != speed else { return }
        let times = speed.times
        update(DSPCompressorParameters.self, commit: true) { current in
            guard current.bands.indices.contains(index) else { return }
            current.bands[index].attackMs = times.attackMs
            current.bands[index].releaseMs = times.releaseMs
            current.useCustomSettings()
        }
    }

    private func compressorSpeedTitle(_ speed: DSPCompressorSpeed) -> String {
        switch speed {
        case .fast: "快"
        case .medium: "中"
        case .slow: "慢"
        }
    }

    private func matchingSpeed(for band: DSPCompressorBand) -> DSPCompressorSpeed? {
        DSPCompressorSpeed.allCases.first { speed in
            let times = speed.times
            return abs(band.attackMs - times.attackMs) < 1e-9
                && abs(band.releaseMs - times.releaseMs) < 1e-9
        }
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
                            current.useCustomSettings()
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

    private func binding<P: DSPEffectParameterSet>(
        _ type: P.Type,
        _ keyPath: WritableKeyPath<P, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { current(type)[keyPath: keyPath] },
            set: { value in update(type, commit: true) { $0[keyPath: keyPath] = value } }
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
        range: ClosedRange<Double>,
        info: String? = nil
    ) -> some View {
        DSPRangeSliderRow(
            title: title,
            value: binding(type, keyPath),
            range: range,
            step: 0.01,
            unit: "",
            fractionDigits: 2,
            info: info,
            onCommit: onCommit
        )
    }

    private func retainsRealBassRow(_ isOn: Binding<Bool>) -> some View {
        HStack {
            Text("保留物理低音")
                .font(.subheadline)
                .settingsInfoHint("关闭后，截止频率以下的原声会被滤去，只由谐波呈现低音，适合难以重放低频的小扬声器。")
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// Parameter sets tuned for a target transducer.
nonisolated protocol DSPBassTargeted {
    var target: DSPBassTarget { get set }
    mutating func switchTarget(to newTarget: DSPBassTarget)
}

nonisolated extension DSPClassicBassParameters: DSPBassTargeted {}
nonisolated extension DSPHybridBassParameters: DSPBassTargeted {}
