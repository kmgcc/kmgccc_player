//
//  AudioDSPEQEditor.swift
//  myPlayer2
//
//  Nine-band EQ response and directly editable band controls.
//

import SwiftUI

struct AudioDSPNodeCard: View {
    let node: DSPNodeConfiguration
    let index: Int
    let nodeCount: Int
    let configuration: AudioDSPConfiguration
    let format: DSPAudioFormat?
    let headroomDB: Double?
    @Binding var isExpanded: Bool
    let onEnabledChange: @MainActor @Sendable (Bool) -> Void
    let onChannelPolicyChange: @MainActor @Sendable (String) -> Void
    let onBandChange: (Int, DSPParametricEQBand) -> Void
    let onCommit: () -> Void
    let onMove: (Int) -> Void
    let onRemove: () -> Void

    var body: some View {
        SettingsSection("均衡器 \(index + 1)") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSwitchRow(
                    title: "启用九段均衡器",
                    isOn: Binding(
                        get: { node.enabled },
                        set: onEnabledChange
                    )
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
                    .accessibilityLabel("上移均衡器")
                    .disabled(index == 0)

                    Button {
                        onMove(1)
                    } label: {
                        Label("下移", systemImage: "chevron.down")
                            .labelStyle(.iconOnly)
                    }
                    .dspIconButtonStyle()
                    .accessibilityLabel("下移均衡器")
                    .disabled(index == nodeCount - 1)

                    Button(role: .destructive, action: onRemove) {
                        Label("移除", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .dspIconButtonStyle()
                    .accessibilityLabel("移除均衡器")
                }

                DisclosureGroup("曲线与频段参数", isExpanded: $isExpanded) {
                    if let bands = node.parametricEQBands {
                        AudioDSPEQEditor(
                            configuration: configuration,
                            node: node,
                            bands: bands,
                            format: format,
                            headroomDB: headroomDB,
                            onBandChange: onBandChange,
                            onCommit: onCommit
                        )
                        .padding(.top, 10)
                    } else {
                        Text("均衡器参数无法读取。")
                            .settingsDescriptionStyle()
                            .padding(.top, 8)
                    }
                }
            }
        }
    }

    private var channelPolicyBinding: Binding<String> {
        Binding(
            get: { node.channelPolicy },
            set: onChannelPolicyChange
        )
    }
}

private struct AudioDSPEQEditor: View {
    let configuration: AudioDSPConfiguration
    let node: DSPNodeConfiguration
    let bands: [DSPParametricEQBand]
    let format: DSPAudioFormat?
    let headroomDB: Double?
    let onBandChange: (Int, DSPParametricEQBand) -> Void
    let onCommit: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @State private var draggedBandIndex: Int?

    private let dbSpan = 18.0
    private let fallbackPreviewSampleRate = 48_000.0
    private let bandColumnWidth: CGFloat = 88

    private var sampleRate: Double {
        guard let sampleRate = format?.sampleRate, sampleRate.isFinite, sampleRate > 0 else {
            return fallbackPreviewSampleRate
        }
        return sampleRate
    }

    private var responseConfiguration: AudioDSPConfiguration {
        var result = configuration
        var responseNode = node
        responseNode.enabled = true
        result.enabled = true
        result.nodes = [responseNode]
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geometry in
                let plot = plotRect(in: geometry.size)
                Canvas { context, size in
                    drawGrid(in: &context, plot: plot)
                    drawResponse(in: &context, plot: plot)
                    drawBandPoints(in: &context, plot: plot)
                    drawLabels(in: &context, plot: plot, size: size)
                }
                .contentShape(Rectangle())
                .gesture(curveDragGesture(in: plot))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("九段均衡器频响曲线")
                .accessibilityValue(accessibilityCurveValue)
                .accessibilityHint("启用频段后，可拖动曲线上的控制点调整频率与增益；也可使用下方参数列。")
            }
            .frame(height: 172)

            HStack {
                Text(format.map { "采样率 \(formatSampleRate($0.sampleRate))" } ?? "预览按 48 kHz 绘制")
                Spacer(minLength: 8)
                if let headroomDB {
                    Text("余量估计 \(headroomDB, format: .number.precision(.fractionLength(1))) dB")
                }
            }
            .settingsDescriptionStyle()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(bands.indices, id: \.self) { index in
                        AudioDSPBandColumn(
                            index: index,
                            band: bands[index],
                            width: bandColumnWidth,
                            onChange: { changedBand in onBandChange(index, changedBand.normalized) },
                            onCommit: onCommit
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("九段均衡器参数")
        }
    }

    private var accessibilityCurveValue: String {
        let enabledCount = bands.filter(\.enabled).count
        return "\(enabledCount) 个频段启用，预览采样率 \(formatSampleRate(sampleRate))"
    }

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: 34,
            y: 8,
            width: max(100, size.width - 42),
            height: max(78, size.height - 30)
        )
    }

    private func drawGrid(in context: inout GraphicsContext, plot: CGRect) {
        for db in stride(from: -18.0, through: 18.0, by: 9.0) {
            let y = dbToY(db, in: plot)
            let thickness: CGFloat = db == 0 ? 0.9 : 0.55
            context.fill(
                Path(CGRect(x: plot.minX, y: y - thickness / 2, width: plot.width, height: thickness)),
                with: .color(Color.primary.opacity(db == 0 ? 0.18 : 0.07)),
            )
        }

        for frequency in [20.0, 100.0, 1_000.0, 10_000.0, 20_000.0] {
            let x = frequencyToX(frequency, in: plot)
            let thickness: CGFloat = 0.55
            context.fill(
                Path(CGRect(x: x - thickness / 2, y: plot.minY, width: thickness, height: plot.height)),
                with: .color(Color.primary.opacity(0.06))
            )
        }
    }

    private func drawResponse(in context: inout GraphicsContext, plot: CGRect) {
        let pointCount = max(100, Int(plot.width * 1.2))
        var responsePoints: [CGPoint] = []
        responsePoints.reserveCapacity(pointCount)
        for index in 0..<pointCount {
            let position = Double(index) / Double(pointCount - 1)
            let logMin = log10(DSPParametricEQBand.frequencyRange.lowerBound)
            let logMax = log10(DSPParametricEQBand.frequencyRange.upperBound)
            let frequency = pow(10, logMin + (logMax - logMin) * position)
            let gain = DSPParametricEQMath.responseDB(
                configuration: responseConfiguration,
                at: frequency,
                sampleRate: sampleRate
            )
            let point = CGPoint(
                x: plot.minX + plot.width * CGFloat(position),
                y: dbToY(gain.isFinite ? gain : 0, in: plot)
            )
            responsePoints.append(point)
        }
        guard responsePoints.count > 1 else { return }

        let normals = responsePoints.indices.map { index -> CGVector in
            let previous = responsePoints[max(0, index - 1)]
            let next = responsePoints[min(responsePoints.count - 1, index + 1)]
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = max(CGFloat(0.001), (dx * dx + dy * dy).squareRoot())
            return CGVector(dx: -dy / length, dy: dx / length)
        }

        let halfWidth: CGFloat = 0.8
        var responseArea = Path()
        let firstNormal = normals[0]
        responseArea.move(to: CGPoint(
            x: responsePoints[0].x + firstNormal.dx * halfWidth,
            y: responsePoints[0].y + firstNormal.dy * halfWidth
        ))
        for index in responsePoints.indices.dropFirst() {
            let point = responsePoints[index]
            let normal = normals[index]
            responseArea.addLine(to: CGPoint(
                x: point.x + normal.dx * halfWidth,
                y: point.y + normal.dy * halfWidth
            ))
        }
        for index in responsePoints.indices.reversed() {
            let point = responsePoints[index]
            let normal = normals[index]
            responseArea.addLine(to: CGPoint(
                x: point.x - normal.dx * halfWidth,
                y: point.y - normal.dy * halfWidth
            ))
        }
        responseArea.closeSubpath()
        context.fill(responseArea, with: .color(themeStore.accentColor))
    }

    private func drawBandPoints(in context: inout GraphicsContext, plot: CGRect) {
        for (index, band) in bands.enumerated() where band.enabled {
            let point = bandPoint(band, in: plot)
            let radius: CGFloat = draggedBandIndex == index ? 5 : 3.5
            let rect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(themeStore.accentColor))
        }
    }

    private func drawLabels(in context: inout GraphicsContext, plot: CGRect, size: CGSize) {
        for db in [-18.0, 0.0, 18.0] {
            context.draw(
                Text(db > 0 ? "+\(Int(db))" : "\(Int(db))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary),
                at: CGPoint(x: 29, y: dbToY(db, in: plot)),
                anchor: .trailing
            )
        }

        for frequency in [20.0, 100.0, 1_000.0, 10_000.0, 20_000.0] {
            let label: String
            switch frequency {
            case 1_000: label = "1k"
            case 10_000: label = "10k"
            default: label = "\(Int(frequency))"
            }
            context.draw(
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary),
                at: CGPoint(x: frequencyToX(frequency, in: plot), y: size.height - 3),
                anchor: .bottom
            )
        }
    }

    private func curveDragGesture(in plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if draggedBandIndex == nil {
                    draggedBandIndex = nearestEnabledBand(to: value.location, in: plot)
                }
                guard let draggedBandIndex else { return }
                updateBand(draggedBandIndex, at: value.location, in: plot)
            }
            .onEnded { _ in
                draggedBandIndex = nil
                onCommit()
            }
    }

    private func nearestEnabledBand(to location: CGPoint, in plot: CGRect) -> Int? {
        let nearest = bands.enumerated()
            .filter { $0.element.enabled }
            .min {
                distanceSquared(location, bandPoint($0.element, in: plot))
                    < distanceSquared(location, bandPoint($1.element, in: plot))
            }
        return nearest?.offset
    }

    private func updateBand(_ index: Int, at location: CGPoint, in plot: CGRect) {
        guard bands.indices.contains(index) else { return }
        var band = bands[index]
        band.frequencyHz = xToFrequency(location.x, in: plot)
        if band.type.usesGain {
            band.gainDB = yToDB(location.y, in: plot)
        }
        onBandChange(index, band.normalized)
    }

    private func bandPoint(_ band: DSPParametricEQBand, in plot: CGRect) -> CGPoint {
        let gain = band.type.usesGain ? band.gainDB : 0
        return CGPoint(x: frequencyToX(band.frequencyHz, in: plot), y: dbToY(gain, in: plot))
    }

    private func frequencyToX(_ frequency: Double, in plot: CGRect) -> CGFloat {
        let low = log10(DSPParametricEQBand.frequencyRange.lowerBound)
        let high = log10(DSPParametricEQBand.frequencyRange.upperBound)
        let clampedFrequency = min(max(frequency, DSPParametricEQBand.frequencyRange.lowerBound), DSPParametricEQBand.frequencyRange.upperBound)
        return plot.minX + plot.width * CGFloat((log10(clampedFrequency) - low) / (high - low))
    }

    private func xToFrequency(_ x: CGFloat, in plot: CGRect) -> Double {
        let low = log10(DSPParametricEQBand.frequencyRange.lowerBound)
        let high = log10(DSPParametricEQBand.frequencyRange.upperBound)
        let boundedX = min(max(x, plot.minX), plot.maxX)
        let amount = Double(boundedX - plot.minX) / Double(max(1, plot.width))
        return pow(10, low + (high - low) * amount)
    }

    private func dbToY(_ db: Double, in plot: CGRect) -> CGFloat {
        let value = min(max(db, -dbSpan), dbSpan)
        return plot.midY - plot.height * CGFloat(value / (dbSpan * 2))
    }

    private func yToDB(_ y: CGFloat, in plot: CGRect) -> Double {
        let boundedY = min(max(y, plot.minY), plot.maxY)
        return Double(plot.midY - boundedY) / Double(max(1, plot.height)) * dbSpan * 2
    }

    private func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private func formatSampleRate(_ sampleRate: Double) -> String {
        "\((sampleRate / 1_000).formatted(.number.precision(.fractionLength(1)))) kHz"
    }
}

private struct AudioDSPBandColumn: View {
    let index: Int
    let band: DSPParametricEQBand
    let width: CGFloat
    let onChange: (DSPParametricEQBand) -> Void
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(index + 1)")
                .font(.system(.caption, design: .rounded).weight(.bold))
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityHidden(true)

            Toggle("启用", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel("启用第 \(index + 1) 段")

            Menu {
                ForEach(DSPFilterType.allCases, id: \.self) { type in
                    Button(type.localizedDSPTitle) {
                        var updated = band
                        updated.type = type
                        onChange(updated.normalized)
                        onCommit()
                    }
                }
            } label: {
                Text(band.type.localizedDSPTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("第 \(index + 1) 段滤波器")

            numericField(title: "频率 Hz", keyPath: \.frequencyHz, digits: 0)
            if band.type.usesGain {
                numericField(title: "增益 dB", keyPath: \.gainDB, digits: 1)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("增益 dB")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("—")
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            numericField(title: band.type.usesSlope ? "Q/S" : "Q", keyPath: \.q, digits: 2)
        }
        .frame(width: width, alignment: .top)
        .padding(8)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { band.enabled },
            set: { value in
                var updated = band
                updated.enabled = value
                onChange(updated.normalized)
                onCommit()
            }
        )
    }

    private func numericField(
        title: String,
        keyPath: WritableKeyPath<DSPParametricEQBand, Double>,
        digits: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(
                title,
                value: valueBinding(keyPath),
                format: .number.precision(.fractionLength(digits))
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospacedDigit())
            .accessibilityLabel("第 \(index + 1) 段\(title)")
            .onSubmit { onCommit() }
        }
    }

    private func valueBinding(_ keyPath: WritableKeyPath<DSPParametricEQBand, Double>) -> Binding<Double> {
        Binding(
            get: { band[keyPath: keyPath] },
            set: { value in
                var updated = band
                updated[keyPath: keyPath] = value
                onChange(updated.normalized)
            }
        )
    }
}

private extension DSPFilterType {
    var localizedDSPTitle: String {
        switch self {
        case .bell: "峰值"
        case .lowShelf: "低架"
        case .highShelf: "高架"
        case .lowPass: "低通"
        case .highPass: "高通"
        case .notch: "陷波"
        }
    }
}

private extension View {
    func dspIconButtonStyle() -> some View {
        buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .clipShape(Capsule())
            .controlSize(.small)
    }
}
