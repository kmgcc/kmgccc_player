//
//  AudioDSPEqualLoudnessCalibration.swift
//  myPlayer2
//
//  Equal-loudness stage status and the four-step calibration guide.
//

import AppKit
import MotionKit
import PopupKit
import SwiftUI

// MARK: - Stage status

/// Device, volume and compensation state shown inside the stage. The
/// calibration shown is the preset's own, when recorded on the routed device.
struct AudioDSPEqualLoudnessStatus: View {
    let stage: DSPEqualLoudnessStage
    let controller: EqualLoudnessController
    let onCalibrate: () -> Void
    let onRemoveCalibration: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isPromptingCalibration = false

    private var calibration: EqualLoudnessCalibration? {
        controller.context.usableCalibration(in: stage)
    }

    private var needsCalibrationPrompt: Bool {
        calibration == nil && controller.volumeState.reading?.isWritable == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                EqualLoudnessCurveChart(
                    stage: stage,
                    context: controller.context,
                    marker: controller.volumeState.reading,
                    chartHeight: 84
                )

                VStack(alignment: .leading, spacing: 8) {
                    statusRow("当前音量", volumeText)
                    statusRow("低频补偿", bassCompensationText)
                    statusRow("高频补偿", trebleCompensationText)
                }
                .frame(width: 175)
            }
            HStack(alignment: .center, spacing: 8) {
                Text(calibration == nil ? "默认曲线" : "已标定")
                    .font(.system(size: 12))
                    .foregroundStyle(themeStore.appForegroundPalette.tertiaryColor)
                Spacer(minLength: 8)
                if calibration != nil {
                    Button("恢复默认", action: onRemoveCalibration)
                        .audioDSPCapsuleButtonStyle()
                }
                Button(calibration == nil ? "标定" : "重新标定", action: onCalibrate)
                    .audioDSPCapsuleButtonStyle()
                    .overlay {
                        if needsCalibrationPrompt {
                            Capsule()
                                .fill(themeStore.accentColor)
                                .overlay(
                                    Text("标定")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.white)
                                )
                                .opacity(isPromptingCalibration ? 1.0 : 0.0)
                                .allowsHitTesting(false)
                        }
                    }
                    .motionAnimation(.control, value: isPromptingCalibration)
                    .disabled(controller.volumeState.reading?.isWritable != true)
            }
            if let reading = controller.volumeState.reading, !reading.isWritable {
                Text("“\(reading.deviceName)”的音量由设备自身调节，无法在此标定。")
                    .settingsDescriptionStyle()
            }
        }
        .task(id: needsCalibrationPrompt) {
            guard needsCalibrationPrompt else {
                isPromptingCalibration = false
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard !Task.isCancelled, needsCalibrationPrompt else { break }
                isPromptingCalibration = true
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                isPromptingCalibration = false
            }
            isPromptingCalibration = false
        }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                .monospacedDigit()
        }
    }

    private var volumeText: String {
        guard let reading = controller.volumeState.reading else { return "音量不可读取" }
        let percent = "\(Int((reading.scalar * 100).rounded()))%"
        let level = reading.decibelsBelowMaximum.map { " · \($0.formatted(.number.precision(.fractionLength(1)))) dB" } ?? ""
        return reading.isMuted ? "已静音 · \(percent)" : percent + level
    }

    private var bassCompensationText: String {
        guard controller.volumeState.reading != nil else { return "已停用" }
        let gains = DSPEqualLoudnessMath.gains(stage: stage, context: controller.context)
        return EqualLoudnessFormat.signedDB(gains.bassDB)
    }

    private var trebleCompensationText: String {
        guard controller.volumeState.reading != nil else { return "已停用" }
        let gains = DSPEqualLoudnessMath.gains(stage: stage, context: controller.context)
        return EqualLoudnessFormat.signedDB(gains.trebleDB)
    }
}

enum EqualLoudnessFormat {
    static func signedDB(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        guard abs(rounded) >= 0.05 else { return "0 dB" }
        let magnitude = abs(rounded).formatted(.number.precision(.fractionLength(1)))
        return (rounded > 0 ? "+" : "−") + magnitude + " dB"
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Compensation against volume, loud on the right, with the current volume
/// marked. The zero line runs through the middle so cuts above the reference
/// read as clearly as boosts below it.
struct EqualLoudnessCurveChart: View {
    let stage: DSPEqualLoudnessStage
    let context: DSPEqualLoudnessContext
    let marker: OutputDeviceVolumeReading?
    var chartHeight: CGFloat = 84

    @EnvironmentObject private var themeStore: ThemeStore

    private let span = 12.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { canvas, size in
                // This chart describes the configured curve, including while bypassed.
                var plottedStage = stage
                plottedStage.enabled = true
                let plot = CGRect(x: 2, y: 4, width: max(1, size.width - 4), height: max(1, size.height - 8))
                let axis = stage.calibration?.axis ?? context.volume.reading?.axis ?? .percent
                let range: ClosedRange<Double> = axis == .decibels ? -60...0 : 0...100
                func x(_ value: Double) -> CGFloat {
                    plot.minX + plot.width * CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                }
                func y(_ gain: Double) -> CGFloat {
                    plot.midY - plot.height / 2 * CGFloat(min(max(gain, -span), span) / span)
                }
                let faint = themeStore.appForegroundPalette.primaryColor
                canvas.fill(Path(CGRect(x: plot.minX, y: plot.midY - 0.3, width: plot.width, height: 0.6)),
                            with: .color(faint.opacity(0.22)))
                var bass = Path()
                var treble = Path()
                let steps = max(180, Int(plot.width * 2))
                for index in 0...steps {
                    let value = range.lowerBound + (range.upperBound - range.lowerBound) * Double(index) / Double(steps)
                    let gains = DSPEqualLoudnessMath.gains(stage: plottedStage, context: sampleContext(at: value, axis: axis))
                    let bassPoint = CGPoint(x: x(value), y: y(gains.bassDB))
                    let treblePoint = CGPoint(x: x(value), y: y(gains.trebleDB))
                    if index == 0 { bass.move(to: bassPoint); treble.move(to: treblePoint) }
                    else { bass.addLine(to: bassPoint); treble.addLine(to: treblePoint) }
                }
                let style = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                canvas.fill(bass.strokedPath(style), with: .color(themeStore.accentColor))
                canvas.fill(treble.strokedPath(style), with: .color(themeStore.accentColor.opacity(0.45)))
                if let marker {
                    let markX = x(min(max(marker.coordinate(on: axis), range.lowerBound), range.upperBound))
                    canvas.fill(Path(CGRect(x: markX - 0.5, y: plot.minY, width: 1, height: plot.height)),
                                with: .color(faint.opacity(0.45)))
                }
            }
            .frame(height: chartHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("补偿随音量变化的曲线")

            HStack(spacing: 14) {
                legend("低频", color: themeStore.accentColor)
                legend("高频", color: themeStore.accentColor.opacity(0.45))
            }
            .font(.system(size: 11))
            .foregroundStyle(themeStore.appForegroundPalette.tertiaryColor)
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 12, height: 2)
            Text(title)
        }
    }

    /// The same device at another volume; the curve comes from the stage.
    private func sampleContext(at value: Double, axis: OutputDeviceVolumeReading.Axis) -> DSPEqualLoudnessContext {
        let reading = OutputDeviceVolumeReading(
            deviceUID: context.volume.deviceUID ?? "", deviceName: "",
            scalar: axis == .percent ? value / 100 : 1,
            decibelsBelowMaximum: axis == .decibels ? value : nil,
            isMuted: false, isWritable: false
        )
        return DSPEqualLoudnessContext(volume: .available(reading), deviceKey: context.deviceKey)
    }
}

// MARK: - Segment picker

/// A clip-style range over the song's level overview: drag either edge to
/// resize, drag the middle to move. The playhead is drawn over it.
struct EqualLoudnessSegmentPicker: View {
    let duration: Double
    let levels: [Float]
    @Binding var start: Double
    @Binding var end: Double
    let playhead: Double?
    let onEditingChanged: (Bool) -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @State private var dragPart: Part?
    @State private var dragOrigin: ClosedRange<Double>?

    static let minimumLength = 5.0
    private let height: CGFloat = 68
    private let handleHitWidth: CGFloat = 20

    private enum Part { case move, start, end }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                let startX = x(start, width)
                let endX = x(end, width)
                ZStack(alignment: .topLeading) {
                    waveform(startX: startX, endX: endX)

                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(themeStore.accentColor.opacity(0.16))
                        .frame(width: max(1, endX - startX), height: height)
                        .offset(x: startX)
                        .contentShape(Rectangle())
                        .pointerStyle(.grabIdle)

                    if let playhead, playhead >= 0, playhead <= duration {
                        Capsule()
                            .fill(themeStore.appForegroundPalette.primaryColor.opacity(0.75))
                            .frame(width: 1.5, height: height - 12)
                            .offset(x: x(playhead, width) - 0.75, y: 6)
                            .allowsHitTesting(false)
                    }

                    handle(at: startX)
                    handle(at: endX)
                }
                .contentShape(Rectangle())
                .gesture(drag(width: width, startX: startX, endX: endX))
            }
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("片段")
            .accessibilityValue("\(EqualLoudnessFormat.time(start)) 至 \(EqualLoudnessFormat.time(end))")

            HStack(alignment: .firstTextBaseline) {
                Text("\(EqualLoudnessFormat.time(start)) – \(EqualLoudnessFormat.time(end))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                Spacer(minLength: 8)
                Text("\(Int((end - start).rounded())) 秒")
                    .font(.system(size: 12))
                    .foregroundStyle(themeStore.appForegroundPalette.tertiaryColor)
            }
            .monospacedDigit()
        }
    }

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return width * CGFloat(min(max(time / duration, 0), 1))
    }

    private func waveform(startX: CGFloat, endX: CGFloat) -> some View {
        let inside = themeStore.accentColor
        let outside = themeStore.appForegroundPalette.primaryColor.opacity(0.22)
        let surface = themeStore.appForegroundPalette.primaryColor.opacity(0.05)
        let bins = levels
        let stripHeight = height
        return Canvas { canvas, size in
            canvas.fill(
                Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 12, style: .continuous),
                with: .color(surface)
            )
            guard !bins.isEmpty else { return }
            let slot = size.width / CGFloat(bins.count)
            let barWidth = max(1.5, slot * 0.55)
            let maximumHeight = stripHeight - 20
            for (index, level) in bins.enumerated() {
                let centerX = slot * (CGFloat(index) + 0.5)
                let barHeight = max(3, CGFloat(level) * maximumHeight)
                let rect = CGRect(x: centerX - barWidth / 2, y: (size.height - barHeight) / 2,
                                  width: barWidth, height: barHeight)
                let isInside = centerX >= startX && centerX <= endX
                canvas.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(isInside ? inside : outside))
            }
        }
        .frame(height: stripHeight)
        .allowsHitTesting(false)
    }

    private func handle(at handleX: CGFloat) -> some View {
        Capsule()
            .fill(themeStore.accentColor)
            .frame(width: 5, height: height - 22)
            .frame(width: handleHitWidth, height: height)
            .contentShape(Rectangle())
            .offset(x: handleX - handleHitWidth / 2)
            .pointerStyle(.columnResize)
    }

    private func drag(width: CGFloat, startX: CGFloat, endX: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragPart == nil {
                    guard let part = part(
                        at: value.startLocation.x,
                        startX: startX,
                        endX: endX
                    ) else { return }
                    dragPart = part
                    dragOrigin = start...end
                    onEditingChanged(true)
                }
                guard let part = dragPart, let origin = dragOrigin, duration > 0 else { return }
                let delta = Double(value.translation.width / width) * duration
                let minimum = min(Self.minimumLength, duration)
                switch part {
                case .move:
                    let length = origin.upperBound - origin.lowerBound
                    let movedStart = min(max(0, origin.lowerBound + delta), max(0, duration - length))
                    start = Self.rounded(movedStart)
                    end = Self.rounded(movedStart + length)
                case .start:
                    start = Self.rounded(min(max(0, origin.lowerBound + delta), end - minimum))
                case .end:
                    end = Self.rounded(max(min(duration, origin.upperBound + delta), start + minimum))
                }
            }
            .onEnded { _ in
                if dragPart != nil { onEditingChanged(false) }
                dragPart = nil
                dragOrigin = nil
            }
    }

    private func part(at locationX: CGFloat, startX: CGFloat, endX: CGFloat) -> Part? {
        let span = max(0, endX - startX)
        let edgeReach = min(handleHitWidth / 2, span / 4)
        if locationX >= startX, locationX <= endX {
            if locationX - startX <= edgeReach { return .start }
            if endX - locationX <= edgeReach { return .end }
            return .move
        }
        if abs(locationX - startX) <= handleHitWidth / 2 { return .start }
        if abs(locationX - endX) <= handleHitWidth / 2 { return .end }
        return nil
    }

    private static func rounded(_ seconds: Double) -> Double { (seconds * 10).rounded() / 10 }
}

// MARK: - Calibration guide

/// Four steps around a moderate reference: the reference itself, two quieter
/// volumes and one louder volume, all over one looping section of a song.
/// The listener moves the volume with the slider here and sets bass and
/// treble so each step sounds as balanced as the reference. Every value set
/// at a step is kept while moving back and forth. The result is saved into
/// the current preset's equal-loudness stage; volume and play order are
/// restored when the guide closes, and abandoning it leaves the preset unchanged.
struct EqualLoudnessCalibrationDialog: View {
    let controller: EqualLoudnessController
    let onSave: (EqualLoudnessCalibration) -> Void
    let onClose: () -> Void

    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore

    private typealias Guide = EqualLoudnessCalibrationGuide

    private enum Phase: Equatable {
        case intro
        case segment
        case step(Int)
        case finished
        case deviceChanged(String)
    }

    /// What the listener set at a step, recorded or not.
    private struct StepDraft: Equatable {
        var bass: Double
        var treble: Double
        var scalar: Double
    }

    @State private var phase: Phase = .intro
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool
    @State private var candidates: [Track] = []
    @State private var selectedTrackID: UUID?
    @State private var points: [EqualLoudnessCalibrationPoint] = []
    @State private var recordedScalars: [Double] = []
    @State private var drafts: [Int: StepDraft] = [:]
    @State private var bass = 0.0
    @State private var treble = 0.0
    @State private var heldMark: Double?
    @State private var startDeviceKey: String?
    @State private var startScalar: Double?
    @State private var calibrationAxis: OutputDeviceVolumeReading.Axis?
    @State private var restoreOrderMode: PlaybackOrderMode?
    @State private var playingQueueTrackID: UUID?
    @State private var segmentTrackID: UUID?
    @State private var segmentStart = 0.0
    @State private var segmentEnd = 15.0
    @State private var segmentDuration = 0.0
    @State private var waveform: [Float] = []
    @State private var isEditingSegment = false
    @State private var lastLoopSeek: TimeInterval = 0

    private var palette: AppForegroundPalette { themeStore.appForegroundPalette }

    var body: some View {
        SettingsTaskDialog(
            title: title,
            subtitle: subtitle,
            systemImage: "ear",
            iconColor: themeStore.accentColor
        ) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            footer
        }
        .frame(minWidth: 540, idealWidth: 560, maxWidth: 620)
        .onExitCommand(perform: onClose)
        .onAppear(perform: begin)
        .onDisappear(perform: restore)
        .onChange(of: controller.routedDeviceKey) { _, key in
            guard phase != .intro, phase != .finished, key != startDeviceKey else { return }
            controller.endCalibration(using: appSession.audioDSPController)
            phase = .deviceChanged(controller.volumeState.deviceName ?? "新设备")
        }
        .task(id: query) { await search() }
        .task(id: segmentTrackID) { await loadWaveform() }
        .task { await runSegmentLoop() }
    }

    // MARK: Text

    private var title: String {
        switch phase {
        case .intro: "标定等响补偿"
        case .segment: "选择音乐片段"
        case .step(let index): Self.stepTitles[index]
        case .finished: "标定完成"
        case .deviceChanged: "输出设备已切换"
        }
    }

    private var subtitle: String {
        switch phase {
        case .intro: "四个音量，约两分钟"
        case .segment, .step, .finished: controller.volumeState.deviceName ?? ""
        case .deviceChanged(let name): "已切换为“\(name)”，请在新设备上重新标定。"
        }
    }

    private static let stepTitles = ["参照音量", "较小的音量", "再轻一些", "调响一些"]

    private static let stepLeads = [
        "在这个音量下聆听片刻，记住低频与高频的分量，后面几步都以它为参照。",
        "声音变轻后，低频和高频可能开始变得不明显。先加强低频，直到分量接近参照；再加强高频，使其重新清晰。",
        "再轻一些，同样补足低频和高频，让声音依旧饱满。",
        "声音变响后，低频和高频容易显得过满。适当减弱，让它与参照一样均衡。",
    ]

    private static let stepNotes = [
        "若这个音量过响或过轻，可移到平时最常用的位置。接下来音量可能会自动变化，请注意。",
        "补偿到接近之前的参照水平即可，过多会沉闷或刺耳。拖回参照刻度，可以随时对照。",
        "补到刚好不觉单薄即可。拖回参照刻度，可以随时对照。",
        "若听来已经合适，保持为 0 即可。",
    ]

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .intro:
            introContent
        case .segment:
            segmentContent
        case .step(let index):
            stepContent(index)
        case .finished:
            finishedContent
        case .deviceChanged:
            EmptyView().frame(minHeight: 12)
        }
    }

    private var introContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("轻声播放时，人耳对低频和高频不再敏感，歌曲因此显得单薄。标定可以记下你在几个音量下所需的补偿，此后计算得到曲线，高低频补偿随音量自然变化。")
                .font(.system(size: 13))
                .foregroundStyle(palette.primaryColor)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            fact("speaker.wave.2", "标定过程中音量可能会自动变小或变大，请注意")

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("参照歌曲")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.primaryColor)
                    Spacer(minLength: 8)
                    Text("选一首熟悉的歌，背景与人声均清晰为佳")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.tertiaryColor)
                }
                searchField
                trackList
            }
        }
        // A click on any blank part of the page ends search editing.
        .contentShape(Rectangle())
        .onTapGesture { isSearchFocused = false }
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(themeStore.accentColor)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryColor)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.tertiaryColor)
            TextField("搜索歌曲", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(palette.primaryColor)
                .focused($isSearchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.tertiaryColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(palette.primaryColor.opacity(0.06)))
    }

    private var trackList: some View {
        AppPopupScrollRegion {
            LazyVStack(spacing: 0) {
                ForEach(candidates, id: \.id) { track in
                    TrackRowView(
                        model: Self.rowModel(track),
                        isPlaying: track.id == playingTrackID,
                        isSelected: track.id == selectedTrackID,
                        enableSecondaryInteractions: false,
                        onTap: { _ in
                            isSearchFocused = false
                            selectedTrackID = track.id
                        },
                        rowPrimaryColor: palette.primaryColor,
                        rowSecondaryColor: palette.secondaryColor,
                        rowTertiaryColor: palette.tertiaryColor,
                        artworkTintMode: AppSettings.shared.artworkTintMode
                    ) { EmptyView() }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(height: 236)
    }

    private var segmentContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("选一段高低频都能明显辨别的段落。标定时它会循环播放，便于在不同音量下对照同一段音乐。")
                .font(.system(size: 13))
                .foregroundStyle(palette.primaryColor)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if let track = selectedTrack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.primaryColor)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryColor)
                        .lineLimit(1)
                }
            }

            EqualLoudnessSegmentPicker(
                duration: segmentDuration,
                levels: waveform,
                start: $segmentStart,
                end: $segmentEnd,
                playhead: playheadTime,
                onEditingChanged: { editing in
                    isEditingSegment = editing
                    if !editing { seek(to: segmentStart) }
                }
            )
        }
    }

    private func stepContent(_ index: Int) -> some View {
        let direction = Guide.directions[index]
        return VStack(alignment: .leading, spacing: 18) {
            stepProgress(index)

            Text(Self.stepLeads[index])
                .font(.system(size: 13))
                .foregroundStyle(palette.primaryColor)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 16) {
                volumeRow(index)
                if direction != .reference {
                    toneRow("低频", value: $bass, range: EqualLoudnessCalibration.bassRange)
                    toneRow("高频", value: $treble, range: EqualLoudnessCalibration.trebleRange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.primaryColor.opacity(0.05))
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(Self.stepNotes[index])
                    .font(.system(size: 12))
                    .foregroundStyle(palette.tertiaryColor)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                if index + 1 < Guide.stepCount, Guide.directions[index + 1] == .louder {
                    Text("下一步音量将变大，请注意")
                        .font(.system(size: 12, weight: .medium))
                        // Explicit green cue requested for the upcoming volume increase.
                        .foregroundStyle(.green)
                }
                if !controller.volumeObserver.isRampingVolume, let message = stepBlocker(index) {
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(themeStore.accentColor)
                }
            }
        }
        .onChange(of: bass) { _, _ in noteToneChange() }
        .onChange(of: treble) { _, _ in noteToneChange() }
    }

    private func stepProgress(_ index: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<Guide.stepCount, id: \.self) { step in
                Capsule()
                    .fill(step <= index ? themeStore.accentColor : palette.primaryColor.opacity(0.1))
                    .frame(height: 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(index + 1) 步，共 \(Guide.stepCount) 步")
    }

    private var finishedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("已为“\(controller.volumeState.deviceName ?? "当前设备")”生成补偿曲线，保存在此设备的音效中。调节音量时，补偿将动态调整高低频以提供始终一致的听感。")
                .font(.system(size: 13))
                .foregroundStyle(palette.primaryColor)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            EqualLoudnessCurveChart(stage: calibratedStage, context: controller.context, marker: controller.volumeState.reading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(palette.primaryColor.opacity(0.05))
                )
        }
    }

    @ViewBuilder
    private var footer: some View {
        Group {
            switch phase {
            case .intro:
                SettingsTaskDialogButton("取消", kind: .secondary, action: onClose)
                SettingsTaskDialogButton("下一步", kind: .primary, disabled: selectedTrackID == nil) {
                    enterSegment()
                }
            case .segment:
                SettingsTaskDialogButton("放弃", kind: .secondary, action: onClose)
                SettingsTaskDialogButton("上一步", kind: .secondary) { phase = .intro }
                SettingsTaskDialogButton("开始标定", kind: .primary, disabled: segmentDuration <= 0) {
                    seek(to: segmentStart)
                    enterStep(0)
                }
            case .step(let index):
                SettingsTaskDialogButton("放弃", kind: .secondary, action: onClose)
                SettingsTaskDialogButton("上一步", kind: .secondary) { goBack(from: index) }
                SettingsTaskDialogButton(index == Guide.stepCount - 1 ? "完成" : "下一步", kind: .primary,
                                         disabled: controller.volumeObserver.isRampingVolume || stepBlocker(index) != nil) {
                    advance(from: index)
                }
            case .finished:
                SettingsTaskDialogButton("重新标定", kind: .secondary) {
                    points = []
                    recordedScalars = []
                    drafts = [:]
                    enterStep(0)
                }
                SettingsTaskDialogButton("完成", kind: .primary, action: onClose)
            case .deviceChanged:
                SettingsTaskDialogButton("好", kind: .primary, action: onClose)
            }
        }
    }

    // MARK: Rows

    private static let labelWidth: CGFloat = 40
    private static let sliderWidth: CGFloat = 300
    private static let valueWidth: CGFloat = 64
    /// Horizontal distance from the slider's edge to the centre of its knob
    /// at either end, so marks line up with knob positions.
    private static let sliderInset: CGFloat = 10

    private func volumeRow(_ index: Int) -> some View {
        let marks = Guide.marks(recorded: recordedScalars, drafted: drafts.mapValues(\.scalar))
        return controlRow("音量", value: "\(Int(((controller.volumeState.reading?.scalar ?? 0) * 100).rounded()))%") {
            VStack(spacing: 3) {
                Slider(value: volumeBinding(marks: marks), in: 0...1)
                    .accessibilityLabel("音量")
                tickRow(height: 12) { width in
                    ForEach(0...16, id: \.self) { sixteenth in
                        let position = Double(sixteenth) / 16
                        if !marks.contains(where: { abs($0 - position) < 1e-6 }) {
                            tick(width: 1, height: 4, color: palette.primaryColor.opacity(0.22))
                                .position(x: Self.sliderInset + width * position, y: 2)
                        }
                    }
                    ForEach(Array(marks.enumerated()), id: \.offset) { step, mark in
                        let isCurrent = step == index
                        tick(width: isCurrent ? 3 : 2, height: isCurrent ? 12 : 7,
                             color: isCurrent ? themeStore.accentColor : palette.primaryColor.opacity(0.45))
                            .position(x: Self.sliderInset + width * min(max(mark, 0), 1), y: isCurrent ? 6 : 3.5)
                    }
                }
            }
        }
    }

    private func toneRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        controlRow(title, value: EqualLoudnessFormat.signedDB(value.wrappedValue)) {
            VStack(spacing: 3) {
                Slider(value: toneBinding(value, range: range), in: range)
                    .accessibilityLabel(title)
                    .accessibilityValue(EqualLoudnessFormat.signedDB(value.wrappedValue))
                tickRow(height: 9) { width in
                    let count = Int((range.upperBound - range.lowerBound) / 3)
                    ForEach(0...count, id: \.self) { step in
                        let gain = range.lowerBound + Double(step) * 3
                        let position = (gain - range.lowerBound) / (range.upperBound - range.lowerBound)
                        let isZero = abs(gain) < 1e-9
                        tick(width: isZero ? 2 : 1, height: isZero ? 9 : 4,
                             color: palette.primaryColor.opacity(isZero ? 0.5 : 0.22))
                            .position(x: Self.sliderInset + width * position, y: isZero ? 4.5 : 2)
                    }
                }
            }
        }
    }

    private func controlRow<Control: View>(
        _ title: String,
        value: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.primaryColor)
                .frame(width: Self.labelWidth, alignment: .leading)
                .padding(.top, 3)
            Spacer(minLength: 0)
            control()
                .frame(width: Self.sliderWidth)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryColor)
                .monospacedDigit()
                .frame(width: Self.valueWidth, alignment: .trailing)
                .padding(.top, 3)
        }
    }

    private func tickRow<Ticks: View>(
        height: CGFloat,
        @ViewBuilder ticks: @escaping (CGFloat) -> Ticks
    ) -> some View {
        GeometryReader { geometry in
            ticks(max(1, geometry.size.width - Self.sliderInset * 2))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func tick(width: CGFloat, height: CGFloat, color: Color) -> some View {
        Capsule().fill(color).frame(width: width, height: height)
    }

    private func volumeBinding(marks: [Double]) -> Binding<Double> {
        Binding(
            get: { controller.volumeState.reading?.scalar ?? 0 },
            set: { value in
                let snapped = Guide.snapped(value, marks: marks, heldMark: heldMark)
                if let mark = snapped.mark, mark != heldMark {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                heldMark = snapped.mark
                controller.volumeObserver.setScalar(snapped.value)
                saveCurrentDraft()
            }
        )
    }

    /// Half-dB steps with a gentle detent at 0 dB.
    private func toneBinding(_ value: Binding<Double>, range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) },
            set: { raw in
                var next = (raw * 2).rounded() / 2
                if abs(raw) < 0.4 { next = 0 }
                if next == 0, value.wrappedValue != 0 {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                if next != value.wrappedValue { value.wrappedValue = next }
            }
        )
    }

    // MARK: Flow

    private func begin() {
        let reading = controller.volumeState.reading
        startDeviceKey = controller.routedDeviceKey
        startScalar = reading?.scalar
        calibrationAxis = reading?.axis
        selectedTrackID = activeSession?.playerViewModel.currentTrack?.id
    }

    /// Plays the chosen song inside a queue of the whole library, so the
    /// listener can move on to other songs once calibration ends; the song
    /// repeats and its chosen section loops while the guide is open.
    private func enterSegment() {
        isSearchFocused = false
        guard let session = activeSession, let track = selectedTrack else { return }
        let player = session.playerViewModel
        if playingQueueTrackID != track.id {
            if player.currentTrack?.id != track.id || !player.isPlaying {
                let library = session.libraryViewModel.allTracks.filter { $0.availability.isPlayable }
                if let coordinator = appSession.playbackCoordinator {
                    coordinator.playTrack(track, inQueueFrom: library)
                } else {
                    player.playTracks(library, startingAt: library.firstIndex(where: { $0.id == track.id }) ?? 0)
                }
                restoreOrderMode = .shuffle
            } else if restoreOrderMode == nil {
                restoreOrderMode = AppSettings.shared.playbackOrderMode
            }
            player.setPlaybackOrderMode(.repeatOne, announceChange: false)
            playingQueueTrackID = track.id
        }
        if segmentTrackID != track.id {
            let duration = max(0, track.duration)
            let length = min(15, duration)
            let start = min(duration * 0.3, max(0, duration - length))
            segmentDuration = duration
            segmentStart = (start * 10).rounded() / 10
            segmentEnd = ((start + length) * 10).rounded() / 10
            waveform = []
            segmentTrackID = track.id
            // A new song starts at the reference volume or quieter.
            if let scalar = controller.volumeState.reading?.scalar, scalar > Guide.suggestedScalars[0] {
                controller.volumeObserver.setScalar(Guide.suggestedScalars[0])
            }
        }
        phase = .segment
        seek(to: segmentStart)
    }

    private func enterStep(_ index: Int) {
        controller.volumeObserver.cancelVolumeRamp()
        controller.beginCalibration(using: appSession.audioDSPController)
        let direction = Guide.directions[index]
        let isNewDraft = drafts[index] == nil
        let target: Double
        if let draft = drafts[index] {
            bass = draft.bass
            treble = draft.treble
            target = draft.scalar
        } else {
            if direction == .quieter, let previous = drafts[index - 1] {
                bass = max(0, previous.bass)
                treble = max(0, previous.treble)
            } else {
                bass = 0
                treble = 0
            }
            target = Guide.suggestedScalar(step: index, recorded: recordedScalars)
        }
        let axis = calibrationAxis ?? controller.volumeState.reading?.axis
        if calibrationAxis == nil { calibrationAxis = axis }
        drafts[index] = StepDraft(bass: bass, treble: treble, scalar: target)
        heldMark = Guide.marks(recorded: recordedScalars, drafted: drafts.mapValues(\.scalar))
            .contains { abs($0 - target) < 1e-6 } ? target : nil
        phase = .step(index)
        updatePreview()
        applyStepVolume(target, at: index, adjustingSpacing: isNewDraft, axis: axis)
    }

    private func applyStepVolume(_ target: Double, at index: Int, adjustingSpacing: Bool,
                                 axis: OutputDeviceVolumeReading.Axis?) {
        controller.volumeObserver.rampScalar(to: target) {
            guard phase == .step(index) else { return }
            saveCurrentDraft()
            guard adjustingSpacing, Guide.directions[index] != .reference, let axis,
                  let reading = controller.volumeState.reading,
                  Guide.blocker(step: index, reading: reading,
                                recordedCoordinates: points.prefix(index).map(\.coordinate),
                                recordedScalars: recordedScalars, axis: axis) != nil else { return }
            let next = Guide.directions[index] == .quieter
                ? max(Guide.lowestSuggestedScalar, target - Guide.volumeStep)
                : min(Guide.highestSuggestedScalar, target + Guide.volumeStep)
            guard next != target else { return }
            drafts[index]?.scalar = next
            heldMark = next
            applyStepVolume(next, at: index, adjustingSpacing: true, axis: axis)
        }
    }

    private func goBack(from index: Int) {
        controller.volumeObserver.cancelVolumeRamp()
        saveCurrentDraft()
        if index == 0 {
            controller.endCalibration(using: appSession.audioDSPController)
            phase = .segment
        } else {
            enterStep(index - 1)
        }
    }

    private func advance(from index: Int) {
        guard !controller.volumeObserver.isRampingVolume, stepBlocker(index) == nil,
              let reading = controller.volumeState.reading else { return }
        saveCurrentDraft()
        let isReference = Guide.directions[index] == .reference
        let currentAxis = calibrationAxis ?? reading.axis
        if Guide.needsPercentageAxisFallback(
            step: index,
            reading: reading,
            recordedCoordinates: points.prefix(index).map(\.coordinate),
            recordedScalars: recordedScalars,
            axis: currentAxis
        ) {
            calibrationAxis = .percent
            for pointIndex in points.indices where recordedScalars.indices.contains(pointIndex) {
                let point = points[pointIndex]
                points[pointIndex] = EqualLoudnessCalibrationPoint(
                    coordinate: recordedScalars[pointIndex] * 100,
                    bassDB: point.bassDB,
                    trebleDB: point.trebleDB
                )
            }
        }
        let axis = calibrationAxis ?? reading.axis
        calibrationAxis = axis
        let point = EqualLoudnessCalibrationPoint(
            coordinate: reading.coordinate(on: axis),
            bassDB: isReference ? 0 : bass,
            trebleDB: isReference ? 0 : treble
        )
        // Later steps keep what was set there; moving back and forward never
        // discards a value.
        if points.indices.contains(index) {
            points[index] = point
            recordedScalars[index] = reading.scalar
        } else {
            points.append(point)
            recordedScalars.append(reading.scalar)
        }
        guard index == Guide.stepCount - 1 else {
            enterStep(index + 1)
            return
        }
        guard let deviceKey = controller.routedDeviceKey else { return }
        let calibration = EqualLoudnessCalibration(
            deviceKey: deviceKey,
            deviceName: reading.deviceName,
            axis: calibrationAxis ?? reading.axis,
            points: Array(points.prefix(Guide.stepCount))
        )
        onSave(calibration)
        controller.endCalibration(using: appSession.audioDSPController, keepingEnabled: true)
        phase = .finished
    }

    /// Why "next" is unavailable, or nil when the step can be recorded.
    private func stepBlocker(_ index: Int) -> String? {
        guard let reading = controller.volumeState.reading else { return "音量不可读取。" }
        return Guide.blocker(
            step: index,
            reading: reading,
            recordedCoordinates: points.prefix(index).map(\.coordinate),
            recordedScalars: recordedScalars,
            axis: calibrationAxis ?? reading.axis
        )
    }

    private func noteToneChange() {
        saveCurrentDraft()
        updatePreview()
    }

    private func saveCurrentDraft() {
        guard case .step(let index) = phase else { return }
        let scalar = (controller.volumeObserver.isRampingVolume ? drafts[index]?.scalar : controller.volumeState.reading?.scalar)
            ?? drafts[index]?.scalar
            ?? Guide.suggestedScalar(step: index, recorded: recordedScalars)
        drafts[index] = StepDraft(bass: bass, treble: treble, scalar: scalar)
    }

    private func updatePreview() {
        guard case .step(let index) = phase else { return }
        let isReference = Guide.directions[index] == .reference
        controller.setPreview(DSPEqualLoudnessGains(
            bassDB: isReference ? 0 : bass,
            trebleDB: isReference ? 0 : treble
        ))
    }

    private func restore() {
        controller.endCalibration(using: appSession.audioDSPController)
        if let startScalar, controller.routedDeviceKey == startDeviceKey {
            controller.volumeObserver.setScalar(startScalar)
        }
        if let restoreOrderMode {
            activeSession?.playerViewModel.setPlaybackOrderMode(restoreOrderMode, announceChange: false)
        }
    }

    // MARK: Section loop

    private var isLooping: Bool {
        guard playingQueueTrackID != nil, !isEditingSegment else { return false }
        switch phase {
        case .segment, .step: return true
        default: return false
        }
    }

    private var playheadTime: Double? {
        guard let player = activeSession?.playerViewModel,
              player.currentTrack?.id == segmentTrackID else { return nil }
        return player.currentTime
    }

    /// Keeps playback inside the chosen section while the guide is open.
    private func runSegmentLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            guard isLooping,
                  let player = activeSession?.playerViewModel,
                  player.currentTrack?.id == segmentTrackID,
                  player.isPlaying else { continue }
            let time = player.currentTime
            // A seek takes a moment to show in the playback clock.
            let now = ProcessInfo.processInfo.systemUptime
            if (time >= segmentEnd || time < segmentStart - 0.75), now - lastLoopSeek > 0.4 {
                seek(to: segmentStart)
            }
        }
    }

    private func seek(to seconds: Double) {
        lastLoopSeek = ProcessInfo.processInfo.systemUptime
        if let coordinator = appSession.playbackCoordinator {
            coordinator.seek(to: seconds)
        } else {
            activeSession?.playerViewModel.seek(to: seconds)
        }
    }

    private func loadWaveform() async {
        guard let id = segmentTrackID,
              let track = activeSession?.libraryViewModel.allTracks.first(where: { $0.id == id }) else { return }
        let resolution = track.resolveFileURL()
        defer { resolution.lease.release() }
        guard let url = resolution.url else { return }
        let levels = await TrackWaveformSampler.levels(url: url, binCount: 120)
        guard !Task.isCancelled, segmentTrackID == id else { return }
        waveform = levels
    }

    // MARK: Song list

    private var activeSession: LibrarySession? { appSession.activeLibraryBinding.activeSession }

    private var selectedTrack: Track? {
        guard let id = selectedTrackID else { return nil }
        return activeSession?.libraryViewModel.allTracks.first { $0.id == id }
    }

    private var playingTrackID: UUID? {
        guard let player = activeSession?.playerViewModel, player.isPlaying else { return nil }
        return player.currentTrack?.id
    }

    private var calibratedStage: DSPEqualLoudnessStage {
        appSession.audioDSPController.configuration.equalLoudness
    }

    private func search() async {
        guard let session = activeSession else { return }
        let library = session.libraryViewModel
        let playable = library.allTracks.filter { $0.availability.isPlayable }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            var rows: [Track] = []
            if let current = session.playerViewModel.currentTrack, current.availability.isPlayable { rows.append(current) }
            let favourites = playable
                .filter { $0.id != rows.first?.id }
                .sorted {
                    session.preferenceStatsService.getPreferenceScore(for: $0.id)
                        > session.preferenceStatsService.getPreferenceScore(for: $1.id)
                }
                .prefix(30)
            candidates = rows + favourites
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let hits = await library.searchTracks(query: trimmed, scopedTo: Set(playable.map(\.id)), limit: 60)
        guard !Task.isCancelled else { return }
        candidates = playable
            .filter { hits[$0.id] != nil }
            .sorted { (hits[$0.id]?.score ?? 0) > (hits[$1.id]?.score ?? 0) }
    }

    private static func rowModel(_ track: Track) -> TrackRowModel {
        let seconds = Int(max(0, track.duration).rounded(.down))
        let artworkFileURL = track.existingArtworkURL()
        let artworkData = artworkFileURL == nil ? track.artworkData : nil
        return TrackRowModel(
            id: track.id,
            title: track.title,
            artist: track.artist,
            lyricSnippetLine: nil,
            lyricSnippetStartTime: nil,
            lyricHighlightRanges: [],
            durationText: String(format: "%d:%02d", seconds / 60, seconds % 60),
            artworkData: artworkData,
            artworkFileURL: artworkFileURL,
            artworkIdentity: PlaylistArtworkPipeline.rowSourceIdentity(
                trackID: track.id, artworkData: artworkData, artworkFileURL: artworkFileURL
            ),
            isMissing: !track.availability.isPlayable,
            artworkTrackID: track.id
        )
    }
}
