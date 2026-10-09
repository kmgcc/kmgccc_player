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
                    CapsulePicker(
                        label: "声道范围",
                        options: ["fullRange", "allChannels"],
                        selection: channelPolicyBinding,
                        displayName: { $0 == "fullRange" ? "全频" : "所有声道" }
                    )

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
                        .equatable()
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

struct AudioDSPEQEditor: View, Equatable {
    let configuration: AudioDSPConfiguration
    let node: DSPNodeConfiguration
    let bands: [DSPParametricEQBand]
    let format: DSPAudioFormat?
    let headroomDB: Double?
    let onBandChange: (Int, DSPParametricEQBand) -> Void
    let onCommit: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @State private var draggedBandIndex: Int?
    @State private var activeBandIndex: Int? = 0

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.node.nodeID == rhs.node.nodeID && lhs.bands == rhs.bands
            && lhs.format == rhs.format && lhs.headroomDB == rhs.headroomDB
    }

    private let dbSpan = 18.0
    private let fallbackPreviewSampleRate = 48_000.0
    private let bandColumnWidth: CGFloat = 88

    private var sampleRate: Double {
        guard let sampleRate = format?.sampleRate, sampleRate.isFinite, sampleRate > 0 else {
            return fallbackPreviewSampleRate
        }
        return sampleRate
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

            HorizontalFadeScrollContainer(
                spacing: 8,
                fadeWidth: 16,
                verticalPadding: 4,
                leadingScrollPadding: 4,
                trailingScrollPadding: 4,
                showsEdgeFade: true,
                showsScrollButtons: true
            ) {
                ForEach(bands.indices, id: \.self) { index in
                    AudioDSPBandColumn(
                        index: index,
                        band: bands[index],
                        width: bandColumnWidth,
                        isActive: activeBandIndex == index,
                        onSelect: { activeBandIndex = index },
                        onChange: { changedBand in
                            activeBandIndex = index
                            onBandChange(index, changedBand.normalized)
                        },
                            onCommit: onCommit
                        )
                }
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
                with: .color(Color.primary.opacity(db == 0 ? 0.18 : 0.07))
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
        // Coefficients depend on the bands and sample rate, not on the plotted
        // frequency. Prepare each filter once per drawing pass.
        let coefficients = bands.filter(\.enabled).compactMap {
            DSPParametricEQMath.coefficients(for: $0, sampleRate: sampleRate)
        }
        let logMin = log10(DSPParametricEQBand.frequencyRange.lowerBound)
        let logMax = log10(DSPParametricEQBand.frequencyRange.upperBound)
        var responsePoints: [CGPoint] = []
        responsePoints.reserveCapacity(pointCount)
        for index in 0..<pointCount {
            let position = Double(index) / Double(pointCount - 1)
            let frequency = pow(10, logMin + (logMax - logMin) * position)
            let gain = coefficients.reduce(0.0) {
                $0 + $1.responseDB(at: frequency, sampleRate: sampleRate)
            }
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
            let isCurrent = (draggedBandIndex == index) || (activeBandIndex == index)
            let radius: CGFloat = isCurrent ? 8.5 : 7.0
            let rect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            if isCurrent {
                // Outer radial accent halo ring
                let outerRadius: CGFloat = 13.0
                let outerRect = CGRect(
                    x: point.x - outerRadius,
                    y: point.y - outerRadius,
                    width: outerRadius * 2,
                    height: outerRadius * 2
                )
                let haloRing = Path(ellipseIn: outerRect).strokedPath(StrokeStyle(lineWidth: 1.5))
                context.fill(haloRing, with: .color(themeStore.accentColor.opacity(0.55)))

                context.fill(Path(ellipseIn: rect), with: .color(themeStore.accentColor))
                context.draw(
                    Text("\(index + 1)")
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white),
                    at: point,
                    anchor: .center
                )
            } else {
                context.fill(Path(ellipseIn: rect), with: .color(themeStore.accentColor.opacity(0.24)))
                context.draw(
                    Text("\(index + 1)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(themeStore.accentColor),
                    at: point,
                    anchor: .center
                )
            }
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
                    if let draggedBandIndex {
                        activeBandIndex = draggedBandIndex
                    }
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
    let isActive: Bool
    let onSelect: () -> Void
    let onChange: (DSPParametricEQBand) -> Void
    let onCommit: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        VStack(spacing: 7) {
            Text("\(index + 1)")
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(isActive ? themeStore.accentColor : .secondary)
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
                        onSelect()
                        onChange(updated.normalized)
                        onCommit()
                    }
                }
            } label: {
                Text(band.type.localizedDSPTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityLabel("第 \(index + 1) 段滤波器")

            scrubbableField(
                title: "频率 Hz",
                keyPath: \.frequencyHz,
                range: DSPParametricEQBand.frequencyRange,
                step: 10,
                unit: "Hz",
                digits: 0
            )

            if band.type.usesGain {
                scrubbableField(
                    title: "增益 dB",
                    keyPath: \.gainDB,
                    range: DSPParametricEQBand.gainRange,
                    step: 0.5,
                    unit: "dB",
                    digits: 1
                )
            } else {
                VStack(spacing: 2) {
                    Text("增益 dB")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("—")
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 3)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }

            scrubbableField(
                title: band.type.usesSlope ? "斜率 S" : "Q",
                keyPath: \.q,
                range: band.type.usesSlope ? DSPParametricEQBand.shelfSlopeRange : DSPParametricEQBand.qRange,
                step: 0.05,
                unit: band.type.usesSlope ? "S" : "",
                digits: 2
            )
        }
        .frame(width: width, alignment: .top)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? themeStore.accentColor.opacity(0.12) : Color.primary.opacity(0.035))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            onSelect()
        }
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

    private func scrubbableField(
        title: String,
        keyPath: WritableKeyPath<DSPParametricEQBand, Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String = "",
        digits: Int
    ) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            ScrubbableNumberField(
                value: valueBinding(keyPath),
                range: range,
                step: step,
                unit: unit,
                fractionDigits: digits,
                alignment: .center,
                onCommit: onCommit
            )
            .accessibilityLabel("第 \(index + 1) 段\(title)")
        }
        .frame(maxWidth: .infinity, alignment: .center)
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

extension View {
    func dspIconButtonStyle() -> some View {
        buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .clipShape(Capsule())
            .controlSize(.small)
    }
}
