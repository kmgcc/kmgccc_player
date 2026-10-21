import AppKit
import MotionKit
import SwiftUI

@MainActor
struct AudioProcessingGlobalsSettingsView: View {
    let controller: AudioProcessingGlobalsController
    @EnvironmentObject private var appSession: AppSessionHost

    @EnvironmentObject private var themeStore: ThemeStore
    @State private var showsFailures = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            fadeSection
            loudnessSection
            errorSection
        }
    }

    private var fadeSection: some View {
        SettingsSection("淡入淡出") {
            SettingsSwitchRow(
                title: "播放与暂停渐变",
                isOn: fadeBinding(\.enabled)
            )
        }
    }

    private var loudnessSection: some View {
        SettingsSection("音量均衡") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSwitchRow(
                    title: "音量均衡",
                    isOn: loudnessBinding(\.enabled),
                    info: "测量歌曲的响度并整体调整电平，使歌曲之间响度一致，曲中的强弱起伏完全保留。"
                )

                LoudnessTargetSliderRow(
                    value: loudnessBinding(\.targetLUFS),
                    accentColor: themeStore.accentColor,
                    tickColor: themeStore.appForegroundPalette.primaryColor
                )
                .disabled(!controller.configuration.loudness.enabled)

                if controller.configuration.loudness.enabled {
                    Divider()
                    measurementContent
                }
            }
        }
    }

    private var measurementContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            let info = currentAdjustmentInfo
            LoudnessAdjustmentMeter(
                gainDB: info.gainDB,
                statusText: info.text,
                accentColor: themeStore.accentColor,
                primaryColor: themeStore.appForegroundPalette.primaryColor
            )

            if let context = activeLocalTrack {
                analyzeButtons(context)
            }

            if let session = appSession.activeLibraryBinding.activeSession {
                libraryContent(session)
            }
        }
    }

    private func analyzeButtons(_ context: (session: LibrarySession, track: Track)) -> some View {
        let state = context.session.loudnessService.measurementState(for: context.track.id)
        return HStack(spacing: 8) {
            Button("分析当前歌曲") {
                context.session.startAutomationLoudnessAnalyze(trackIDs: [context.track.id])
            }
            .disabled(isBusy(state))
            .audioDSPCapsuleButtonStyle()

            Button("分析当前专辑") {
                context.session.startAutomationLoudnessAnalyze(trackIDs: albumTrackIDs(context))
            }
            .disabled(albumTrackIDs(context).count < 2)
            .audioDSPCapsuleButtonStyle()
        }
    }

    @ViewBuilder
    private func libraryContent(_ session: LibrarySession) -> some View {
        let service = session.loudnessService
        let tracks = session.libraryViewModel.allTracks
        let failedIDs = service.failedTrackIDs(in: tracks.map(\.id))
        let progress = service.libraryProgress(trackIDs: tracks.map(\.id))
        let total = max(1, tracks.count)
        // The scan progress is only shown while songs are still pending.
        if progress.remaining > 0 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(progress.measured.formatted()) / \(tracks.count.formatted()) 首")
                        .settingsDescriptionStyle()
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    if service.isIdleScanPausedByListener {
                        Button("继续分析") { session.resumeIdleLoudnessScan() }
                            .audioDSPCapsuleButtonStyle()
                    }
                }

                LoudnessProgressBar(
                    measuredFraction: Double(progress.measured) / Double(total),
                    failedFraction: Double(progress.failed) / Double(total),
                    fillColor: themeStore.accentColor,
                    failedColor: themeStore.appForegroundPalette.secondaryColor,
                    trackColor: themeStore.appForegroundPalette.primaryColor.opacity(0.14)
                )

                if let status = libraryStatusText(session, progress: progress) {
                    Text(status)
                        .settingsDescriptionStyle()
                }
            }
        }

        if !failedIDs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    CollapsibleSectionHeader(
                        "无法测量的歌曲 \(failedIDs.count.formatted())",
                        systemImage: "exclamationmark.circle",
                        isExpanded: $showsFailures
                    )
                    Button("全部重试") {
                        session.startAutomationLoudnessAnalyze(trackIDs: failedIDs, force: true)
                    }
                    .audioDSPCapsuleButtonStyle()
                }
                if showsFailures {
                    let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(failedIDs, id: \.self) { id in
                                failureRow(session: session, trackID: id, track: byID[id])
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .modifier(ScrollEdgeFadeTrackingMask(topFadeHeight: 14, bottomFadeHeight: 14))
                    .frame(maxHeight: 220)
                }
            }
        }
    }

    private func failureRow(session: LibrarySession, trackID: UUID, track: Track?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "未知歌曲")
                    .settingsRowLabelStyle()
                    .lineLimit(1)
                Text([track?.artist, session.loudnessService.failureMessage(for: trackID)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "："))
                    .settingsDescriptionStyle()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("重试") {
                session.startAutomationLoudnessAnalyze(trackIDs: [trackID], force: true)
            }
            .audioDSPCapsuleButtonStyle()
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

    // MARK: - Current Track Loudness Adjustment

    private var currentAdjustmentInfo: (gainDB: Double?, text: String) {
        guard let context = activeLocalTrack else {
            return (nil, "未在播放")
        }
        let service = context.session.loudnessService
        let state = service.measurementState(for: context.track.id)

        switch state {
        case .unmeasured:
            return (nil, "未测量")
        case .waiting(let priority):
            if priority == .idleBatch, let reason = appSession.backgroundWorkScheduler.idleWaitReason {
                return (nil, reason.message)
            }
            return (nil, "排队测量")
        case .measuring(let phase, let fraction):
            if let fraction {
                return (nil, "\(phase.title) \(Int((fraction * 100).rounded()))%")
            }
            return (nil, phase.title)
        case .paused:
            return (nil, "已暂停")
        case .failed(let message):
            return (nil, message)
        case .measured:
            let plan = context.session.audioNormalizationPlan
            let gain: Double
            if let audible = context.session.audioNormalizationAudibleGainDB {
                gain = audible
            } else if let planGain = plan?.decision.gainDB {
                gain = planGain
            } else if let record = service.record(for: context.track.id),
                      let measurement = record.measurement,
                      measurement.isUsable {
                let decision = LoudnessGainSelector.trackGain(
                    configuration: controller.configuration.loudness,
                    measurement: measurement
                )
                gain = decision.gainDB
            } else {
                return (0, "0.0 dB")
            }

            if gain < -0.05 {
                let formatted = abs(gain).formatted(.number.precision(.fractionLength(1)))
                return (gain, "衰减 \(formatted) dB")
            } else if gain > 0.05 {
                let formatted = gain.formatted(.number.precision(.fractionLength(1)))
                return (gain, "增加 \(formatted) dB")
            } else {
                return (0, "0.0 dB")
            }
        }
    }

    /// Only states that the bar cannot show; nil when the scan is finished.
    private func libraryStatusText(_ session: LibrarySession, progress: LoudnessLibraryProgress) -> String? {
        guard progress.remaining > 0 else { return nil }
        if session.loudnessService.isIdleScanPausedByListener {
            return "已暂停"
        }
        return appSession.backgroundWorkScheduler.idleWaitReason?.message
    }

    private func isBusy(_ state: LoudnessTrackMeasurementState) -> Bool {
        if case .measuring = state { return true }
        return false
    }

    // MARK: - Bindings

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

    private var activeLocalTrack: (session: LibrarySession, track: Track)? {
        guard appSession.playbackCoordinator?.activeSource == .local,
              let session = appSession.activeLibraryBinding.activeSession,
              let track = session.playerViewModel.currentTrack else {
            return nil
        }
        return (session, track)
    }

    private func albumTrackIDs(_ context: (session: LibrarySession, track: Track)) -> [UUID] {
        guard !context.track.albumGroupKey.isEmpty else { return [] }
        return context.session.libraryViewModel.allTracks
            .filter { $0.albumGroupKey == context.track.albumGroupKey }
            .map(\.id)
    }
}

/// Library scan progress: measured songs in the accent color, failed songs in
/// a muted tone, the rest on the track.
private struct LoudnessProgressBar: View {
    let measuredFraction: Double
    let failedFraction: Double
    let fillColor: Color
    let failedColor: Color
    let trackColor: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                // Failed songs sit behind the measured ones so both start at the lead edge.
                Capsule()
                    .fill(failedColor)
                    .frame(width: width * (measuredFraction + failedFraction))
                Capsule()
                    .fill(fillColor)
                    .frame(width: width * measuredFraction)
            }
            .motionAnimation(.control, value: measuredFraction)
            .motionAnimation(.control, value: failedFraction)
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// Target loudness with a detent at the recommended −14 LUFS, whose mark
/// stays lit under the slider.
private struct LoudnessTargetSliderRow: View {
    @Binding var value: Double
    let accentColor: Color
    let tickColor: Color

    private let range = AudioLoudnessConfiguration.targetRange
    private let recommended = AudioLoudnessConfiguration.defaultTargetLUFS
    private let sliderInset: CGFloat = 10
    private static let valueWidth: CGFloat = 68

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("目标响度")
                .settingsRowLabelStyle()
                .settingsInfoHint("均衡后每首歌的平均响度。推荐值 −14 LUFS，与多数流媒体平台相当。")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)

            VStack(spacing: 3) {
                Slider(value: binding, in: range)
                    .accessibilityLabel("目标响度")
                    .accessibilityValue("\(value.formatted(.number.precision(.fractionLength(1)))) LUFS")
                GeometryReader { geometry in
                    let width = max(1, geometry.size.width - sliderInset * 2)
                    let span = range.upperBound - range.lowerBound
                    ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: 1)), id: \.self) { mark in
                        let isRecommended = abs(mark - recommended) < 1e-9
                        Capsule()
                            .fill(isRecommended ? accentColor : tickColor.opacity(0.22))
                            .frame(width: isRecommended ? 3 : 1, height: isRecommended ? 10 : 4)
                            .position(x: sliderInset + width * (mark - range.lowerBound) / span,
                                      y: isRecommended ? 5 : 2)
                    }
                }
                .frame(height: 10)
                .accessibilityHidden(true)
                HStack {
                    Text("较轻")
                    Spacer(minLength: 0)
                    Text("较响")
                }
                .settingsDescriptionStyle()
            }
            .frame(width: DSPRangeSliderRow.sliderWidth + 40)

            Text("\(value.formatted(.number.precision(.fractionLength(1)))) LUFS")
                .font(.caption.monospacedDigit())
                .settingsDescriptionStyle()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: Self.valueWidth, alignment: .trailing)
                .padding(.top, 2)
        }
    }

    /// Half-LUFS steps; within 0.4 of the recommended value the slider rests
    /// on it.
    private var binding: Binding<Double> {
        Binding(
            get: { min(max(value, range.lowerBound), range.upperBound) },
            set: { raw in
                var next = (raw * 2).rounded() / 2
                if abs(raw - recommended) < 0.4 { next = recommended }
                if next == recommended, value != recommended {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                if next != value { value = next }
            }
        )
    }
}

/// Visual bipolar meter showing the current track's loudness attenuation or boost.
private struct LoudnessAdjustmentMeter: View {
    let gainDB: Double?
    let statusText: String
    let accentColor: Color
    let primaryColor: Color

    private let meterSpan: Double = 16.0
    private let barHeight: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("当前调整")
                    .settingsRowLabelStyle()
                Spacer(minLength: 8)
                Text(statusText)
                    .settingsDescriptionStyle()
                    .monospacedDigit()
            }

            VStack(spacing: 4) {
                GeometryReader { geometry in
                    let width = max(1, geometry.size.width)
                    let midX = width * 0.5
                    let clamped = gainDB.map { min(max($0, -meterSpan), meterSpan) }

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(primaryColor.opacity(0.12))

                        if let gain = clamped, abs(gain) > 0.05 {
                            let fraction = abs(gain) / meterSpan
                            let fillWidth = max(2, (width * 0.5) * fraction)
                            if gain < 0 {
                                Capsule()
                                    .fill(accentColor.opacity(0.85))
                                    .frame(width: fillWidth)
                                    .offset(x: midX - fillWidth)
                            } else {
                                Capsule()
                                    .fill(accentColor)
                                    .frame(width: fillWidth)
                                    .offset(x: midX)
                            }
                        }

                        Capsule()
                            .fill(primaryColor.opacity(0.35))
                            .frame(width: 2, height: barHeight + 4)
                            .position(x: midX, y: barHeight * 0.5)
                    }
                    .frame(height: barHeight)
                    .motionAnimation(.control, value: gainDB)
                }
                .frame(height: barHeight + 4)

                HStack {
                    Text("衰减")
                    Spacer(minLength: 0)
                    Text("0 dB")
                    Spacer(minLength: 0)
                    Text("增加")
                }
                .font(.caption2)
                .settingsDescriptionStyle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前响度调整")
        .accessibilityValue(statusText)
    }
}
