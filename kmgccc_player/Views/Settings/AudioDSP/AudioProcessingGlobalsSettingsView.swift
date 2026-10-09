import AppKit
import SwiftUI

@MainActor
struct AudioProcessingGlobalsSettingsView: View {
    let controller: AudioProcessingGlobalsController
    @EnvironmentObject private var appSession: AppSessionHost
    @State private var loudnessAnalysisMessage: String?
    @State private var outputDeviceNames: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            fadeSection
            loudnessSection
            loudnessMeasurementSection
            referenceSection
            errorSection
        }
        .task(id: controller.runtimeState.outputDeviceUID) {
            outputDeviceNames = Dictionary(uniqueKeysWithValues: AudioOutputLatencyMonitor.availableOutputDevices().map { ($0.uniqueID, $0.name) })
        }
    }

    private var fadeSection: some View {
        SettingsSection("淡入淡出") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSwitchRow(
                    title: "播放与暂停渐变",
                    isOn: fadeBinding(\.enabled)
                )

                Text("播放和暂停时，以平滑音量曲线切换。")
                    .settingsDescriptionStyle()

                AudioProcessingRangeSliderRow(
                    title: "播放淡入",
                    value: fadeBinding(\.playFadeMs),
                    range: 10...2_000,
                    step: 10,
                    unit: "ms"
                )
                .disabled(!controller.configuration.fade.enabled)

                AudioProcessingRangeSliderRow(
                    title: "暂停淡出",
                    value: fadeBinding(\.pauseFadeMs),
                    range: 10...2_000,
                    step: 10,
                    unit: "ms"
                )
                .disabled(!controller.configuration.fade.enabled)

                Picker("曲线", selection: fadeBinding(\.curve)) {
                    Text("感知音量").tag("perceptualDB")
                }
                .disabled(!controller.configuration.fade.enabled)

                AudioProcessingRangeSliderRow(
                    title: "淡化底值",
                    value: fadeBinding(\.floorDB),
                    range: -100 ... -40,
                    step: 1,
                    unit: "dB"
                )
                .disabled(!controller.configuration.fade.enabled)
            }
        }
    }

    private var loudnessSection: some View {
        SettingsSection("音量均衡") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSwitchRow(
                    title: "启用音量均衡",
                    isOn: loudnessBinding(\.enabled)
                )

                Picker("应用范围", selection: loudnessBinding(\.mode)) {
                    Text("自动").tag("auto")
                    Text("曲目").tag("track")
                    Text("专辑").tag("album")
                }
                .pickerStyle(.segmented)
                .disabled(!controller.configuration.loudness.enabled)

                AudioProcessingRangeSliderRow(
                    title: "目标响度",
                    value: loudnessBinding(\.targetLUFS),
                    range: -30 ... -10,
                    step: 0.1,
                    unit: "LUFS"
                )
                .disabled(!controller.configuration.loudness.enabled)

                AudioProcessingRangeSliderRow(
                    title: "最大提升",
                    value: loudnessBinding(\.maxBoostDB),
                    range: 0...24,
                    step: 0.1,
                    unit: "dB"
                )
                .disabled(!controller.configuration.loudness.enabled)

                AudioProcessingRangeSliderRow(
                    title: "最大衰减",
                    value: loudnessBinding(\.maxAttenuationDB),
                    range: 0...60,
                    step: 0.1,
                    unit: "dB"
                )
                .disabled(!controller.configuration.loudness.enabled)

                AudioProcessingRangeSliderRow(
                    title: "真实峰值上限",
                    value: loudnessBinding(\.truePeakCeilingDBTP),
                    range: -12...0,
                    step: 0.1,
                    unit: "dBTP"
                )
                .disabled(!controller.configuration.loudness.enabled)

                SettingsSwitchRow(
                    title: "允许后台分析",
                    isOn: loudnessBinding(\.allowBackgroundScan)
                )
                .disabled(!controller.configuration.loudness.enabled)

                Text("没有完整响度数据时保持原音量。")
                    .settingsDescriptionStyle()
            }
        }
    }

    private var referenceSection: some View {
        SettingsSection("等响补偿参考") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("音量来源")
                        .settingsRowLabelStyle()
                    Spacer(minLength: 8)
                    Text(volumeSourceLabel)
                        .settingsDescriptionStyle()
                }

                if let deviceUID = controller.runtimeState.outputDeviceUID {
                    Text("当前输出设备：\(deviceUID)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .settingsDescriptionStyle()

                    if let referenceDB = controller.runtimeState.referenceDB {
                        Text("当前设备参考 \(referenceDB.formatted(.number.precision(.fractionLength(1)))) dB")
                            .settingsDescriptionStyle()
                    } else {
                        Text("按满音量基准进行相对补偿。")
                            .settingsDescriptionStyle()
                    }

                    HStack(spacing: 8) {
                        Button("以当前音量为参考") {
                            do {
                                _ = try controller.useCurrentVolumeAsReference()
                            } catch {
                                controller.report(error: error)
                            }
                        }
                        .disabled(controller.runtimeState.appGain <= 0)
                        .audioDSPCapsuleButtonStyle()

                        if controller.runtimeState.referenceDB != nil {
                            Button("清除参考") {
                                do {
                                    _ = try controller.setDeviceReference(nil, for: deviceUID)
                                } catch {
                                    controller.report(error: error)
                                }
                            }
                            .audioDSPCapsuleButtonStyle()
                        }
                    }
                } else {
                    Text("当前输出设备尚未识别；将按满音量基准进行相对补偿。")
                        .settingsDescriptionStyle()
                }

                if !controller.configuration.deviceReferences.isEmpty {
                    Divider()
                    ForEach(controller.configuration.deviceReferences.keys.sorted(), id: \.self) { deviceUID in
                        HStack(spacing: 8) {
                            Text(outputDeviceNames[deviceUID] ?? deviceUID)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .settingsDescriptionStyle()
                                .accessibilityLabel("输出设备标识，\(deviceUID)")
                            Spacer(minLength: 4)
                            if let value = controller.configuration.deviceReferences[deviceUID] {
                                Text("\(value.formatted(.number.precision(.fractionLength(1)))) dB")
                                    .font(.caption.monospacedDigit())
                                    .settingsDescriptionStyle()
                            }
                            Button("清除") {
                                do {
                                    _ = try controller.setDeviceReference(nil, for: deviceUID)
                                } catch {
                                    controller.report(error: error)
                                }
                            }
                            .audioDSPCapsuleButtonStyle()
                        }
                    }
                }
            }
        }
    }

    private var loudnessMeasurementSection: some View {
        SettingsSection("响度测量") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("当前增益")
                        .settingsRowLabelStyle()
                    Spacer(minLength: 8)
                    Text("\(currentLoudnessGainText) · \(loudnessSourceLabel)")
                        .settingsDescriptionStyle()
                        .monospacedDigit()
                }

                Text("测量完成后，后续播放使用新结果。")
                    .settingsDescriptionStyle()

                HStack(spacing: 8) {
                    Button("分析当前曲目") {
                        guard let context = activeLocalTrack else { return }
                        startLoudnessAnalysis([context.track.id], in: context.session)
                    }
                    .disabled(activeLocalTrack == nil)
                    .audioDSPCapsuleButtonStyle()

                    Button("分析当前专辑") {
                        guard let context = activeLocalTrack else { return }
                        let albumIDs = context.session.libraryViewModel.allTracks
                            .filter { $0.albumGroupKey == context.track.albumGroupKey }
                            .map(\.id)
                        startLoudnessAnalysis(albumIDs, in: context.session)
                    }
                    .disabled(activeLocalTrack == nil || currentAlbumTrackIDs.isEmpty)
                    .audioDSPCapsuleButtonStyle()
                }

                if let loudnessAnalysisMessage {
                    Text(loudnessAnalysisMessage)
                        .settingsDescriptionStyle()
                }
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = controller.lastError {
            SettingsSection("状态信息") {
                HStack(alignment: .top, spacing: 8) {
                    Label(error.message, systemImage: "exclamationmark.circle")
                        .fixedSize(horizontal: false, vertical: true)
                        .settingsDescriptionStyle()
                    Spacer(minLength: 4)
                    Button("清除", action: controller.clearErrors)
                        .audioDSPCapsuleButtonStyle()
                }
            }
        }
    }

    private func fadeBinding<Value>(
        _ keyPath: WritableKeyPath<AudioFadeConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { controller.configuration.fade[keyPath: keyPath] },
            set: { value in
                controller.updateConfiguration { $0.fade[keyPath: keyPath] = value }
            }
        )
    }

    private func loudnessBinding<Value>(
        _ keyPath: WritableKeyPath<AudioLoudnessConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { controller.configuration.loudness[keyPath: keyPath] },
            set: { value in
                controller.updateConfiguration { $0.loudness[keyPath: keyPath] = value }
            }
        )
    }

    private var volumeSourceLabel: String {
        controller.runtimeState.volumeSource == "appOnly" ? "应用音量" : "其他音量来源"
    }

    private var activeLocalTrack: (session: LibrarySession, track: Track)? {
        guard appSession.playbackCoordinator?.activeSource == .local,
              let session = appSession.activeLibraryBinding.activeSession,
              let track = session.playerViewModel.currentTrack else {
            return nil
        }
        return (session, track)
    }

    private var currentLoudnessGainText: String {
        guard let gainDB = activeLocalTrack?.session.audioNormalizationGainDB else { return "—" }
        return "\(gainDB.formatted(.number.precision(.fractionLength(1)))) dB"
    }

    private var loudnessSourceLabel: String {
        guard activeLocalTrack != nil,
              let source = appSession.activeLibraryBinding.activeSession?.audioNormalizationSource else {
            return "无本地曲目"
        }
        switch source {
        case "measured.bs1770": return "测量数据"
        case "metadata.r128", "metadata.replaygain": return "音频标签"
        case "unity.missing": return "未测量"
        case "unity.metadataReferenceUnknown": return "参考数据缺失"
        case "disabled": return "已关闭"
        case "unavailable": return "暂不可用"
        default:
            if source.hasPrefix("measured.") { return "测量数据" }
            if source.hasPrefix("metadata.") { return "音频标签" }
            if source.hasPrefix("unity.") { return "等待完整测量" }
            return "暂不可用"
        }
    }

    private var currentAlbumTrackIDs: [UUID] {
        guard let context = activeLocalTrack,
              !context.track.albumGroupKey.isEmpty else { return [] }
        return context.session.libraryViewModel.allTracks
            .filter { $0.albumGroupKey == context.track.albumGroupKey }
            .map(\.id)
    }

    private func startLoudnessAnalysis(_ trackIDs: [UUID], in session: LibrarySession) {
        guard !trackIDs.isEmpty else { return }
        let message = session.startAutomationLoudnessAnalyze(trackIDs: trackIDs) == nil
            ? "当前资料库暂时无法开始分析。"
            : "已加入后台分析。"
        loudnessAnalysisMessage = message
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }
}

private struct AudioProcessingRangeSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    @State private var draftValue: Double
    @State private var isEditing = false

    init(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String
    ) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
        _draftValue = State(initialValue: value.wrappedValue)
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .settingsRowLabelStyle()
                Text("\(draftValue.formatted(.number.precision(.fractionLength(1)))) \(unit)")
                    .font(.caption.monospacedDigit())
                    .settingsDescriptionStyle()
            }
            .frame(minWidth: 116, alignment: .leading)

            Slider(value: $draftValue, in: range, step: step, onEditingChanged: { editing in
                isEditing = editing
                if !editing {
                    value = draftValue
                }
            })
            .accessibilityLabel(title)
            .accessibilityValue("\(draftValue.formatted(.number.precision(.fractionLength(1)))) \(unit)")
        }
        .onChange(of: value) { _, updatedValue in
            if !isEditing { draftValue = updatedValue }
        }
    }
}
