//
//  AudioDSPEQEditor.swift
//  myPlayer2
//
//  Nine-band EQ response and directly editable band controls.
//

import SwiftUI

struct AudioDSPEQEditor: View, Equatable {
    let node: DSPNodeConfiguration
    let bands: [DSPParametricEQBand]
    let sampleRate: Double?
    let onBandChange: (Int, DSPParametricEQBand) -> Void
    let onCommit: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var dragSession: CurveDragSession?
    @State private var activeBandIndex: Int? = 0
    @State private var curveCache = DSPEQCurveCache()

    /// Closures are intentionally excluded: they route by node ID, which is
    /// compared, and always reach the same controller.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.node.nodeID == rhs.node.nodeID && lhs.bands == rhs.bands
            && lhs.sampleRate == rhs.sampleRate
    }

    private let dbSpan = 18.0
    private let fallbackPreviewSampleRate = 48_000.0
    private let bandColumnWidth: CGFloat = 60
    /// A press must land this close to a control point to start dragging it.
    private let bandHitRadius: CGFloat = 14

    private var resolvedSampleRate: Double {
        guard let sampleRate, sampleRate.isFinite, sampleRate > 0 else {
            return fallbackPreviewSampleRate
        }
        return sampleRate
    }

    var body: some View {
        let palette = DSPRackPalette(themeStore: themeStore, colorScheme: colorScheme)
        let pointColors = BandPointColors(
            current: themeStore.accentColor,
            currentLabel: .white,
            other: palette.mutedMark,
            otherLabel: themeStore.appForegroundPalette.primaryColor
        )
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geometry in
                let plot = plotRect(in: geometry.size)
                Canvas { context, size in
                    drawGrid(in: &context, plot: plot)
                    drawResponse(in: &context, plot: plot)
                    drawBandPoints(in: &context, plot: plot, colors: pointColors)
                    drawLabels(in: &context, plot: plot, size: size)
                }
                .contentShape(Rectangle())
                .gesture(curveDragGesture(in: plot))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("九段均衡器频响曲线")
                .accessibilityValue(accessibilityCurveValue)
                .accessibilityHint("拖动控制点调整频率与增益。")
            }
            .frame(height: 172)

            HorizontalFadeScrollContainer(
                spacing: 6,
                fadeWidth: 16,
                verticalPadding: 2,
                leadingScrollPadding: 0,
                trailingScrollPadding: 0,
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
        return "\(enabledCount) 个频段启用"
    }

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: 34,
            y: 8,
            width: max(100, size.width - 42),
            height: max(78, size.height - 30)
        )
    }

    // MARK: - Drawing

    private func drawGrid(in context: inout GraphicsContext, plot: CGRect) {
        for db in stride(from: -18.0, through: 18.0, by: 9.0) {
            let y = dbToY(db, in: plot)
            let thickness: CGFloat = db == 0 ? 0.9 : 0.55
            context.fill(
                Path(CGRect(x: plot.minX, y: y - thickness / 2, width: plot.width, height: thickness)),
                with: .color(Color.primary.opacity(db == 0 ? 0.18 : 0.07))
            )
        }

        for frequency in Self.gridFrequencies {
            let x = frequencyToX(frequency, in: plot)
            let thickness: CGFloat = 0.55
            context.fill(
                Path(CGRect(x: x - thickness / 2, y: plot.minY, width: thickness, height: plot.height)),
                with: .color(Color.primary.opacity(0.06))
            )
        }
    }

    private func drawResponse(in context: inout GraphicsContext, plot: CGRect) {
        // The ribbon depends only on this node's bands, the sample rate and the
        // plot rect. Every other parameter edit redraws the canvas without
        // changing any of them, so the response is memoized by that key.
        guard let ribbon = curveCache.ribbon(
            bands: bands, sampleRate: resolvedSampleRate, plot: plot, dbSpan: dbSpan
        ) else { return }
        context.fill(ribbon, with: .color(themeStore.accentColor))
    }

    /// Points are opaque; the current band uses the accent and the others a
    /// foreground tier, so overlapping points never blend.
    private func drawBandPoints(in context: inout GraphicsContext, plot: CGRect, colors: BandPointColors) {
        let highlighted = dragSession?.bandIndex ?? activeBandIndex
        let enabled = bands.indices.filter { bands[$0].enabled }
        // The current point is drawn last so it stays on top.
        let order = enabled.filter { $0 != highlighted } + enabled.filter { $0 == highlighted }
        for index in order {
            let point = bandPoint(bands[index], in: plot)
            let isCurrent = highlighted == index
            let radius: CGFloat = isCurrent ? 8.5 : 7.5
            let rect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .color(isCurrent ? colors.current : colors.other)
            )
            context.draw(
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isCurrent ? colors.currentLabel : colors.otherLabel),
                at: point,
                anchor: .center
            )
        }
    }

    private func drawLabels(in context: inout GraphicsContext, plot: CGRect, size: CGSize) {
        for db in [-18.0, 0.0, 18.0] {
            context.draw(
                Text(db > 0 ? "+\(Int(db))" : "\(Int(db))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary),
                at: CGPoint(x: 29, y: dbToY(db, in: plot)),
                anchor: .trailing
            )
        }

        for frequency in Self.gridFrequencies {
            let label: String
            switch frequency {
            case 1_000: label = "1k"
            case 10_000: label = "10k"
            case 20_000: label = "20k"
            default: label = "\(Int(frequency))"
            }
            context.draw(
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary),
                at: CGPoint(x: frequencyToX(frequency, in: plot), y: size.height - 3),
                anchor: .bottom
            )
        }
    }

    private static let gridFrequencies: [Double] = [20, 100, 1_000, 10_000, 20_000]

    // MARK: - Curve Dragging

    /// A drag only edits a band when it starts on that band's control point.
    /// The grab offset keeps the point under the same spot of the pointer, so a
    /// press slightly off-center never makes the point jump.
    private func curveDragGesture(in plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragSession == nil {
                    guard let index = hitBand(at: value.startLocation, in: plot) else { return }
                    let point = bandPoint(bands[index], in: plot)
                    dragSession = CurveDragSession(
                        bandIndex: index,
                        grabOffset: CGSize(
                            width: point.x - value.startLocation.x,
                            height: point.y - value.startLocation.y
                        )
                    )
                    activeBandIndex = index
                }
                guard let session = dragSession else { return }
                let target = CGPoint(
                    x: value.location.x + session.grabOffset.width,
                    y: value.location.y + session.grabOffset.height
                )
                if updateBand(session.bandIndex, at: target, in: plot), !session.didChange {
                    dragSession?.didChange = true
                }
            }
            .onEnded { _ in
                let didChange = dragSession?.didChange == true
                dragSession = nil
                if didChange { onCommit() }
            }
    }

    private func hitBand(at location: CGPoint, in plot: CGRect) -> Int? {
        let limit = bandHitRadius * bandHitRadius
        return bands.indices
            .filter { bands[$0].enabled }
            .map { ($0, distanceSquared(location, bandPoint(bands[$0], in: plot))) }
            .filter { $0.1 <= limit }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// Returns whether the band actually changed.
    @discardableResult
    private func updateBand(_ index: Int, at location: CGPoint, in plot: CGRect) -> Bool {
        guard bands.indices.contains(index) else { return false }
        var band = bands[index]
        band.frequencyHz = xToFrequency(location.x, in: plot).rounded()
        if band.type.usesGain {
            band.gainDB = (yToDB(location.y, in: plot) * 10).rounded() / 10
        }
        let normalized = band.normalized
        guard normalized != bands[index] else { return false }
        onBandChange(index, normalized)
        return true
    }

    // MARK: - Coordinate Mapping

    private func bandPoint(_ band: DSPParametricEQBand, in plot: CGRect) -> CGPoint {
        let gain = band.type.usesGain ? band.gainDB : 0
        return CGPoint(x: frequencyToX(band.frequencyHz, in: plot), y: dbToY(gain, in: plot))
    }

    private func frequencyToX(_ frequency: Double, in plot: CGRect) -> CGFloat {
        let range = DSPParametricEQBand.frequencyRange
        let low = log10(range.lowerBound)
        let high = log10(range.upperBound)
        let clampedFrequency = min(max(frequency, range.lowerBound), range.upperBound)
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
}

private struct BandPointColors {
    let current: Color
    let currentLabel: Color
    let other: Color
    let otherLabel: Color
}

private struct CurveDragSession: Equatable {
    let bandIndex: Int
    let grabOffset: CGSize
    var didChange = false
}

/// Memoizes the filled response ribbon for one band set, sample rate and plot
/// rect. Building it costs one `DSPBiquadCoefficients.responseDB` evaluation per
/// plotted sample per enabled band, which is far too heavy to repeat on every
/// unrelated parameter edit.
private final class DSPEQCurveCache {
    private struct Key: Equatable {
        var bands: [DSPParametricEQBand]
        var sampleRate: Double
        var plot: CGRect
        var dbSpan: Double
    }

    private var key: Key?
    private var ribbon: Path?

    func ribbon(
        bands: [DSPParametricEQBand],
        sampleRate: Double,
        plot: CGRect,
        dbSpan: Double
    ) -> Path? {
        let candidate = Key(bands: bands, sampleRate: sampleRate, plot: plot, dbSpan: dbSpan)
        if key == candidate { return ribbon }
        let computed = Self.makeRibbon(
            bands: bands, sampleRate: sampleRate, plot: plot, dbSpan: dbSpan
        )
        key = candidate
        ribbon = computed
        return computed
    }

    private static func makeRibbon(
        bands: [DSPParametricEQBand],
        sampleRate: Double,
        plot: CGRect,
        dbSpan: Double
    ) -> Path? {
        let pointCount = max(100, Int(plot.width * 1.2))
        // Coefficients depend on the bands and sample rate, not on the plotted
        // frequency. Prepare each filter once per ribbon.
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
            let bounded = min(max(gain.isFinite ? gain : 0, -dbSpan), dbSpan)
            responsePoints.append(CGPoint(
                x: plot.minX + plot.width * CGFloat(position),
                y: plot.midY - plot.height * CGFloat(bounded / (dbSpan * 2))
            ))
        }
        guard responsePoints.count > 1 else { return nil }

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
        return responseArea
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = DSPRackPalette(themeStore: themeStore, colorScheme: colorScheme)
        VStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? themeStore.accentColor : .secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityHidden(true)

            Toggle("启用", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel("启用第 \(index + 1) 段")

            VStack(spacing: 10) {
                Picker("滤波器", selection: typeBinding) {
                    ForEach(DSPFilterType.allCases, id: \.self) { type in
                        Text(type.localizedDSPTitle).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel("第 \(index + 1) 段滤波器")

                scrubbableField(
                    title: "频率",
                    keyPath: \.frequencyHz,
                    range: DSPParametricEQBand.frequencyRange,
                    step: 1,
                    unit: "Hz",
                    digits: 0,
                    scale: .logarithmic(decadesPerPoint: 0.003)
                )

                if band.type.usesGain {
                    scrubbableField(
                        title: "增益",
                        keyPath: \.gainDB,
                        range: DSPParametricEQBand.gainRange,
                        step: 0.1,
                        unit: "dB",
                        digits: 1,
                        scale: .linear(perPoint: 0.04)
                    )
                } else {
                    VStack(spacing: 2) {
                        Text("增益")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("—")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityHidden(true)
                }

                // Q and shelf slope are ratio-like and need fine control, so
                // they scrub slowly on a logarithmic scale.
                scrubbableField(
                    title: band.type.usesSlope ? "斜率" : "Q",
                    keyPath: \.q,
                    range: band.type.usesSlope ? DSPParametricEQBand.shelfSlopeRange : DSPParametricEQBand.qRange,
                    step: 0.01,
                    unit: "",
                    digits: 2,
                    scale: .logarithmic(decadesPerPoint: 0.0015)
                )
            }
            .opacity(band.enabled ? 1 : 0.5)
        }
        .frame(width: width, alignment: .top)
        .padding(.horizontal, 5)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? palette.activeBandSurface : palette.bandSurface)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            onSelect()
        }
    }

    private var typeBinding: Binding<DSPFilterType> {
        Binding(
            get: { band.type },
            set: { type in
                guard type != band.type else { return }
                var updated = band
                updated.type = type
                onSelect()
                onChange(updated.normalized)
                onCommit()
            }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { band.enabled },
            set: { value in
                guard value != band.enabled else { return }
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
        unit: String,
        digits: Int,
        scale: ScrubScale
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
                scrubScale: scale,
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
