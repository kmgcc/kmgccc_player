//
//  DSPCompressorMeterView.swift
//  myPlayer2
//
//  Gain-reduction picture of the multiband compressor: the low, mid and high
//  regions tile a log-frequency strip with its frequency axis below, and the
//  master stage sits apart on the right in the accent's complement. Each
//  region hangs a reduction bar from its top edge. The gaps between the
//  bands are the crossovers: they take the column-resize cursor and drag
//  directly, showing the frequency while they move.
//
//  Readings come from `DSPMeterBus` as they become audible and follow the
//  same spring as the capsule spectrum; crossover changes from elsewhere
//  follow the `control` token, a drag follows the pointer exactly.
//

import AppKit
import MotionKit
import SwiftUI

struct DSPCompressorMeter: NSViewRepresentable {
    let nodeID: UUID
    let lowCrossoverHz: Double
    let highCrossoverHz: Double
    let isActive: Bool
    let accentColor: Color
    let masterColor: Color
    /// Live crossover values while a handle is dragged.
    let onCrossoversChange: (_ low: Double, _ high: Double) -> Void
    /// The drag ended.
    let onCommit: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionPolicy) private var configuredMotionPolicy
    @Environment(\.motionTokens) private var motionTokens

    func makeNSView(context: Context) -> DSPCompressorMeterView {
        DSPCompressorMeterView(nodeID: nodeID)
    }

    func updateNSView(_ view: DSPCompressorMeterView, context: Context) {
        view.motionPolicy = configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
        view.onCrossoversChange = onCrossoversChange
        view.onCommit = onCommit
        view.configure(
            nodeID: nodeID,
            crossovers: (lowCrossoverHz, highCrossoverHz),
            controlSpec: motionTokens[.control],
            colors: DSPCardVisualColors(accent: NSColor(accentColor), isDark: colorScheme == .dark),
            masterColor: NSColor(masterColor),
            isActive: isActive
        )
    }

    static func dismantleNSView(_ view: DSPCompressorMeterView, coordinator: ()) {
        view.stopListening()
    }
}

final class DSPCompressorMeterView: DSPCardAnimatedView {
    /// Reduction that fills a region from top to bottom.
    private static let fullScaleDB: Float = 24
    private static let masterShare: CGFloat = 0.14
    private static let gap: CGFloat = 4
    private static let barInset: CGFloat = 4
    static let axisHeight: CGFloat = 16
    /// Horizontal reach of a crossover handle on either side of its gap.
    private static let handleReach: CGFloat = 7
    private static let axisTicks: [(frequency: Double, label: String)] = [
        (50, "50"), (100, "100"), (200, "200"), (500, "500"),
        (1_000, "1k"), (2_000, "2k"), (5_000, "5k"), (10_000, "10k"),
    ]

    var onCrossoversChange: ((Double, Double) -> Void)?
    var onCommit: (() -> Void)?

    private var nodeID: UUID
    private var isActive = false
    private var colors: DSPCardVisualColors?
    private var masterColor: CGColor?
    private var controlSpec = MotionTokens.standard[.control]
    private var crossovers = DSPFollowerBank(count: 2, spec: MotionTokens.standard[.control], policy: .full)
    private var reductions = DSPFollowerBank(count: 4, spec: CapsuleSpectrumDynamics.standard.motionSpec, policy: .full)
    private var hasPlacedCrossovers = false
    private var frequencies = (low: 200.0, high: 2_500.0)
    private var draggedHandle: Int?
    private var hoveredHandle: Int?
    private var trackingArea: NSTrackingArea?

    private let regionLayers = (0..<4).map { _ in CALayer() }
    private let barLayers = (0..<4).map { _ in CALayer() }
    private let handleLayers = (0..<2).map { _ in CALayer() }
    private let valueLabel = CATextLayer()
    private let axisLabels = DSPCompressorMeterView.axisTicks.map { _ in CATextLayer() }

    init(nodeID: UUID) {
        self.nodeID = nodeID
        super.init(frame: .zero)
        for (region, bar) in zip(regionLayers, barLayers) {
            region.cornerRadius = 6
            region.cornerCurve = .continuous
            bar.cornerRadius = 3
            bar.cornerCurve = .continuous
            layer?.addSublayer(region)
            layer?.addSublayer(bar)
        }
        for handle in handleLayers {
            handle.cornerRadius = 1.5
            layer?.addSublayer(handle)
        }
        let axisFont = NSFont.systemFont(ofSize: 9, weight: .regular)
        for (label, tick) in zip(axisLabels, Self.axisTicks) {
            label.string = tick.label
            label.font = axisFont
            label.fontSize = 9
            label.alignmentMode = .center
            layer?.addSublayer(label)
        }
        valueLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        valueLabel.fontSize = 10
        valueLabel.alignmentMode = .center
        valueLabel.cornerRadius = 7
        valueLabel.isHidden = true
        layer?.addSublayer(valueLabel)
        applyContentsScale()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        nodeID: UUID,
        crossovers values: (low: Double, high: Double),
        controlSpec: MotionSpec,
        colors: DSPCardVisualColors,
        masterColor: NSColor,
        isActive: Bool
    ) {
        if nodeID != self.nodeID {
            DSPMeterBus.shared.cancelWake(for: self.nodeID)
            self.nodeID = nodeID
        }
        self.controlSpec = controlSpec
        crossovers.update(spec: controlSpec, policy: motionPolicy)
        // The dragged values are already in place; the binding echoes them.
        if draggedHandle == nil {
            frequencies = values
            let time = CACurrentMediaTime()
            crossovers.setTarget(DSPCardSpectrumFeed.axisPosition(of: values.low), at: 0, time: time)
            crossovers.setTarget(DSPCardSpectrumFeed.axisPosition(of: values.high), at: 1, time: time)
            if !hasPlacedCrossovers {
                crossovers.snapAll()
                hasPlacedCrossovers = true
            }
        }
        let master = (masterColor.usingColorSpace(.sRGB) ?? masterColor).cgColor
        if colors != self.colors || isActive != self.isActive || master != self.masterColor {
            self.colors = colors
            self.isActive = isActive
            self.masterColor = master
            applyColors()
        }
        wake()
    }

    func stopListening() {
        DSPMeterBus.shared.cancelWake(for: nodeID)
    }

    override func motionPolicyDidChange() {
        reductions.update(spec: CapsuleSpectrumDynamics.standard.motionSpec, policy: motionPolicy)
        crossovers.update(spec: controlSpec, policy: motionPolicy)
    }

    override func visibilityDidChange(_ isVisible: Bool) {
        if !isVisible { DSPMeterBus.shared.cancelWake(for: nodeID) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyContentsScale()
    }

    override func renderFrame(at time: CFTimeInterval) -> Bool {
        let readings = isActive ? DSPMeterBus.shared.latest(for: nodeID) : nil
        for index in 0..<4 {
            let reduction = readings.map { $0.count > index ? $0[index] : 0 } ?? 0
            reductions.setTarget(Double(min(1, max(0, reduction / Self.fullScaleDB))), at: index, time: time)
        }
        let reductionsMoving = reductions.advance(to: time)
        let crossoversMoving = crossovers.advance(to: time)
        let moving = reductionsMoving || crossoversMoving
        draw()
        if readings != nil { return true }
        if !moving, isActive, isVisibleOnScreen {
            // Sleep until the compressor reports again.
            DSPMeterBus.shared.wakeOnNextReading(for: nodeID) { [weak self] in self?.wake() }
        }
        return moving
    }

    // MARK: Geometry

    private var graphHeight: CGFloat { max(0, bounds.height - Self.axisHeight) }

    private var bandWidth: CGFloat {
        bounds.width - (bounds.width * Self.masterShare).rounded() - Self.gap * 2
    }

    /// Centre of each crossover gap.
    private func handleX(_ index: Int) -> CGFloat {
        let low = bandWidth * CGFloat(crossovers.value(0))
        return index == 0 ? low : bandWidth * CGFloat(max(crossovers.value(1), crossovers.value(0)))
    }

    private func handle(at point: CGPoint) -> Int? {
        guard point.y >= 0, point.y <= graphHeight else { return nil }
        let distances = (0..<2).map { abs(point.x - handleX($0)) }
        guard let nearest = distances.indices.min(by: { distances[$0] < distances[$1] }),
              distances[nearest] <= Self.handleReach else { return nil }
        return nearest
    }

    private func frequency(atX x: CGFloat) -> Double {
        let position = Double(min(max(x / max(bandWidth, 1), 0), 1))
        let ratio = DSPCardSpectrumFeed.highestHz / DSPCardSpectrumFeed.lowestHz
        return DSPCardSpectrumFeed.lowestHz * pow(ratio, position)
    }

    // MARK: Pointer

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        updateHover(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard draggedHandle == nil else { return }
        setHovered(nil)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = handle(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        draggedHandle = index
        setHovered(index)
        NSCursor.columnResize.set()
        drag(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggedHandle != nil else {
            super.mouseDragged(with: event)
            return
        }
        drag(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard draggedHandle != nil else {
            super.mouseUp(with: event)
            return
        }
        draggedHandle = nil
        onCommit?()
        updateHover(convert(event.locationInWindow, from: nil))
    }

    private func updateHover(_ point: CGPoint) {
        guard draggedHandle == nil else { return }
        let index = handle(at: point)
        setHovered(index)
        (index == nil ? NSCursor.arrow : NSCursor.columnResize).set()
    }

    private func setHovered(_ index: Int?) {
        guard index != hoveredHandle else { return }
        hoveredHandle = index
        applyColors()
        draw()
    }

    /// Moves the dragged crossover under the pointer, keeping the mid band
    /// at least an octave wide by pushing the other one.
    private func drag(to point: CGPoint) {
        guard let index = draggedHandle else { return }
        let low = DSPCompressorParameters.lowCrossoverRange
        let high = DSPCompressorParameters.highCrossoverRange
        var values = frequencies
        let raw = frequency(atX: point.x)
        if index == 0 {
            values.low = Self.rounded(min(max(raw, low.lowerBound), low.upperBound))
            if values.high < values.low * 2 { values.high = min(high.upperBound, values.low * 2) }
        } else {
            values.high = Self.rounded(min(max(raw, high.lowerBound), high.upperBound))
            if values.high < values.low * 2 { values.low = max(low.lowerBound, values.high / 2) }
        }
        frequencies = values
        let time = CACurrentMediaTime()
        crossovers.setTarget(DSPCardSpectrumFeed.axisPosition(of: values.low), at: 0, time: time, epsilon: 0)
        crossovers.setTarget(DSPCardSpectrumFeed.axisPosition(of: values.high), at: 1, time: time, epsilon: 0)
        crossovers.snapAll()
        onCrossoversChange?(values.low, values.high)
        draw()
    }

    /// Steps that read cleanly: 1 Hz to 200 Hz, then 5, 10 and 50 Hz.
    private static func rounded(_ frequency: Double) -> Double {
        let step: Double = frequency < 200 ? 1 : frequency < 1_000 ? 5 : frequency < 5_000 ? 10 : 50
        return (frequency / step).rounded() * step
    }

    private static func label(_ frequency: Double) -> String {
        guard frequency >= 1_000 else { return "\(Int(frequency.rounded())) Hz" }
        let kilohertz = frequency / 1_000
        let text = kilohertz.formatted(.number.precision(.fractionLength(0...2)))
        return "\(text) kHz"
    }

    // MARK: Drawing

    private func applyContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        valueLabel.contentsScale = scale
        for label in axisLabels { label.contentsScale = scale }
    }

    private func applyColors() {
        guard let colors else { return }
        let master = masterColor ?? colors.accent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, region) in regionLayers.enumerated() {
            let base = index == 3 ? master : colors.accent
            region.backgroundColor = base.copy(alpha: colors.isDark ? 0.12 : 0.09)
        }
        for (index, bar) in barLayers.enumerated() {
            let base = index == 3 ? master : colors.accent
            bar.backgroundColor = base.copy(alpha: isActive ? 0.62 : 0.3)
        }
        for (index, handle) in handleLayers.enumerated() {
            let emphasized = index == hoveredHandle || index == draggedHandle
            handle.backgroundColor = colors.ink(alpha: emphasized ? 0.55 : 0.2)
        }
        for label in axisLabels { label.foregroundColor = colors.ink(alpha: 0.4) }
        // A solid chip in the ink colour, its text in the background's.
        valueLabel.backgroundColor = colors.ink(alpha: 0.78)
        valueLabel.foregroundColor = colors.isDark ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
        CATransaction.commit()
    }

    private func draw() {
        let size = bounds.size
        let height = graphHeight
        guard size.width > 0, height > 0 else { return }
        let masterWidth = (size.width * Self.masterShare).rounded()
        let bandWidth = self.bandWidth
        let lowX = handleX(0)
        let highX = handleX(1)
        let gap = Self.gap
        let regions = [
            CGRect(x: 0, y: 0, width: max(0, lowX - gap / 2), height: height),
            CGRect(x: lowX + gap / 2, y: 0, width: max(0, highX - lowX - gap), height: height),
            CGRect(x: highX + gap / 2, y: 0, width: max(0, bandWidth - highX - gap / 2), height: height),
            CGRect(x: size.width - masterWidth, y: 0, width: masterWidth, height: height),
        ]

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<4 {
            let region = regions[index]
            regionLayers[index].frame = region
            let barWidth = max(0, region.width - Self.barInset * 2)
            let barHeight = (height - Self.barInset * 2) * CGFloat(min(1, max(0, reductions.value(index))))
            barLayers[index].frame = CGRect(x: region.minX + Self.barInset, y: Self.barInset,
                                            width: barWidth, height: barHeight)
            barLayers[index].isHidden = barHeight < 0.5
        }
        // Grips in the gaps, a third of the graph tall.
        let gripHeight = max(10, height * 0.36)
        for (index, x) in [lowX, highX].enumerated() {
            handleLayers[index].frame = CGRect(x: x - 1.5, y: (height - gripHeight) / 2, width: 3, height: gripHeight)
        }
        // Axis labels under the band strip, dropped where they would crowd an edge.
        for (label, tick) in zip(axisLabels, Self.axisTicks) {
            let x = bandWidth * CGFloat(DSPCardSpectrumFeed.axisPosition(of: tick.frequency))
            let width: CGFloat = 26
            label.frame = CGRect(x: x - width / 2, y: height + 3, width: width, height: 12)
            label.isHidden = x - width / 2 < 0 || x + width / 2 > bandWidth
        }
        if let index = draggedHandle {
            let text = Self.label(index == 0 ? frequencies.low : frequencies.high)
            valueLabel.string = text
            let width = CGFloat(text.count) * 6.2 + 14
            let x = min(max(handleX(index) - width / 2, 0), size.width - width)
            valueLabel.frame = CGRect(x: x, y: max(0, (height - 14) / 2), width: width, height: 14)
            valueLabel.isHidden = false
        } else {
            valueLabel.isHidden = true
        }
        CATransaction.commit()
    }
}
