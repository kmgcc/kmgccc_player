//
//  LedMeterView.swift
//  myPlayer2
//
//  kmgccc_player - 11-Dot LED Level Meter with Liquid Glass
//  Center dot (6th) lights first, then symmetrically outward.
//  Each dot has configurable brightness levels (default 5).
//  Liquid Glass material for unlit state and outline.
//

import AppKit
import SwiftUI

/// 11-dot LED level meter with symmetric lighting from center.
/// Uses Liquid Glass material for unlit dots and outline highlights.
struct LedMeterView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    /// Normalized level (0.0 to 1.0)
    let level: Double

    /// Optional per-LED brightness values (0.0 to 1.0)
    var ledValues: [Float]? = nil

    /// Dot size
    var dotSize: CGFloat = 12

    /// Spacing between dots
    var spacing: CGFloat = 7

    /// Optional pill tint (very subtle, above glass)
    var pillTint: Color? = nil

    var isPlaying: Bool = false
    var forceBrightLEDColors: Bool = false

    // MARK: - Settings (from AppSettings)

    private var numLEDs: Int {
        ledValues?.count ?? AppSettings.shared.ledCount
    }

    private var brightnessLevels: Int {
        AppSettings.shared.ledBrightnessLevels
    }

    // MARK: - Resolver

    private var resolver: LEDColorResolver {
        LEDColorResolver(
            accentColor: themeStore.accentColor,
            colorScheme: forceBrightLEDColors ? .dark : colorScheme,
            brightnessLevels: brightnessLevels,
            palette: themeStore.semanticPalette
        )
    }

    // MARK: - Discrete Breath Timing

    private let breathHoldTime: Double = 0.32
    private let peakHoldTime: Double   = 0.60
    private let zeroHoldTime: Double   = 0.40

    private func breathStep(at date: Date) -> Int {
        guard brightnessLevels > 1 else { return 0 }
        let maxStep = brightnessLevels - 1
        if !isPlaying { return maxStep }
        let riseDuration  = Double(maxStep) * breathHoldTime
        let fallDuration  = Double(maxStep) * breathHoldTime
        let cycleDuration = riseDuration + peakHoldTime + fallDuration + zeroHoldTime

        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycleDuration)

        if t < riseDuration {
            let step = Int(t / breathHoldTime)
            return min(maxStep, step)
        } else if t < riseDuration + peakHoldTime {
            return maxStep
        } else if t < riseDuration + peakHoldTime + fallDuration {
            let dt = t - (riseDuration + peakHoldTime)
            let step = Int(dt / breathHoldTime)
            return max(1, maxStep - step)
        } else {
            return 1
        }
    }

    var body: some View {
        let horizontalPadding: CGFloat = 14
        let verticalPadding: CGFloat = 10

        // Idle-CPU: only drive the 20Hz breath animation while playing. When
        // paused the breath value is constant (see `breathStep`) and `ledValues`
        // are frozen, so pausing the timeline avoids a 20Hz Canvas relayout +
        // glass-pill recomposite with no visible change.
        TimelineView(.animation(minimumInterval: 0.05, paused: !isPlaying)) { timeline in
            let breath = breathStep(at: timeline.date)

            HStack(spacing: spacing) {
                statusLed(level: breath)
                divider
                ForEach(0..<numLEDs, id: \.self) { index in
                    ledDot(at: index, breathLevel: breath)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                Capsule()
                    .fill(Color.clear)
                    .liquidGlassPill(
                        colorScheme: colorScheme,
                        accentColor: pillTint,
                        prominence: pillTint != nil ? .prominent : .standard,
                        isFloating: false
                    )
            )
        }
        .animation(.easeInOut(duration: 0.25), value: numLEDs)
    }

    // MARK: - Status Light (Breath LED)

    private func statusLed(level: Int) -> some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: dotSize, height: dotSize)

            Circle()
                .fill(resolver.statusLightColor(level: level))
                .frame(width: dotSize, height: dotSize)
                .opacity(level > 0 ? 1.0 : 0.0)

            Circle()
                .stroke(resolver.statusLightStrokeColor(level: level), lineWidth: 0.7)
                .frame(width: dotSize, height: dotSize)
                .opacity(level > 0 ? 1.0 : 0.0)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: dotSize * 0.6)
    }

    // MARK: - LED Dot

    @ViewBuilder
    private func ledDot(at index: Int, breathLevel breath: Int) -> some View {
        let brightnessState = calculateBrightnessState(for: index)
        let ledColor = resolver.volumeLEDColor(index: index, count: numLEDs, level: brightnessState)
        let strokeColor = resolver.volumeLEDStrokeColor(index: index, count: numLEDs, level: brightnessState)

        ZStack {
            // Unlit glass base — faint outline when off
            Circle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: dotSize, height: dotSize)

            // Lit LED fill — visible only when brightnessState > 0
            Circle()
                .fill(ledColor)
                .frame(width: dotSize, height: dotSize)
                .opacity(brightnessState > 0 ? 1.0 : 0.0)

            // Subtle stroke — visible only when brightnessState > 0
            Circle()
                .stroke(strokeColor, lineWidth: 0.7)
                .frame(width: dotSize, height: dotSize)
                .opacity(brightnessState > 0 ? 1.0 : 0.0)
        }
        .animation(.easeOut(duration: 0.03), value: brightnessState)
    }

    // MARK: - Brightness Calculation

    /// Brightness state: 0 = off (glass only), 1..brightnessLevels-1 = lit levels
    private func calculateBrightnessState(for index: Int) -> Int {
        if let ledValues, index < ledValues.count {
            let value = max(0, min(1, Double(ledValues[index])))
            let step = 1.0 / Double(max(1, brightnessLevels - 1))
            return min(brightnessLevels - 1, Int(round(value / step)))
        }

        let centerIndex = numLEDs / 2
        let distanceFromCenter = abs(index - centerIndex)
        let ledsFromCenterToEdge = numLEDs / 2 + 1
        let totalSlots = ledsFromCenterToEdge * brightnessLevels
        let currentSlot = level * Double(totalSlots)
        let ledStartSlot = Double(distanceFromCenter * brightnessLevels)

        if currentSlot < ledStartSlot {
            return 0
        } else if currentSlot >= ledStartSlot + Double(brightnessLevels) {
            return brightnessLevels - 1
        } else {
            let slotWithinLed = currentSlot - ledStartSlot
            let level = Int(slotWithinLed)
            return min(level, brightnessLevels - 1)
        }
    }
}

/// Live LED meter renderer for Now Playing / fullscreen skins.
///
/// The high-frequency audio stream is consumed inside an AppKit layer host, so
/// parent SwiftUI views do not observe 30Hz LED metrics just to redraw the same
/// skin layout. SwiftUI still owns the static material shell and color policy.
struct LiveLedMeterView: View {
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var dotSize: CGFloat = 12
    var spacing: CGFloat = 7
    var pillTint: Color? = nil
    var isPlaying: Bool = false
    var forceBrightLEDColors: Bool = false

    private var ledCount: Int {
        AppSettings.shared.ledCount
    }

    private var brightnessLevels: Int {
        AppSettings.shared.ledBrightnessLevels
    }

    private var contentWidth: CGFloat {
        dotSize * CGFloat(ledCount + 1) + 1 + spacing * CGFloat(ledCount + 1)
    }

    private var resolver: LEDColorResolver {
        LEDColorResolver(
            accentColor: themeStore.accentColor,
            colorScheme: forceBrightLEDColors ? .dark : colorScheme,
            brightnessLevels: brightnessLevels,
            palette: themeStore.semanticPalette
        )
    }

    var body: some View {
        let horizontalPadding: CGFloat = 14
        let verticalPadding: CGFloat = 10
        let configuration = LiveLedMeterLayerConfiguration(
            ledCount: ledCount,
            brightnessLevels: brightnessLevels,
            dotSize: dotSize,
            spacing: spacing,
            isPlaying: isPlaying,
            colors: LiveLedMeterLayerColors(
                resolver: resolver,
                count: ledCount,
                brightnessLevels: brightnessLevels,
                scheme: forceBrightLEDColors ? .dark : colorScheme
            )
        )

        LiveLedMeterLayerRepresentable(
            provider: ledMeterProvider,
            configuration: configuration
        )
        .frame(width: contentWidth, height: dotSize)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(
            Capsule()
                .fill(Color.clear)
                .liquidGlassPill(
                    colorScheme: colorScheme,
                    accentColor: pillTint,
                    prominence: pillTint != nil ? .prominent : .standard,
                    isFloating: false
                )
        )
    }
}

private struct LiveLedMeterLayerConfiguration {
    let ledCount: Int
    let brightnessLevels: Int
    let dotSize: CGFloat
    let spacing: CGFloat
    let isPlaying: Bool
    let colors: LiveLedMeterLayerColors
}

private struct LiveLedMeterLayerColors {
    let signature: Int
    let baseFill: CGColor
    let dividerFill: CGColor
    let statusFill: [CGColor]
    let statusStroke: [CGColor]
    let ledFill: [[CGColor]]
    let ledStroke: [[CGColor]]

    init(
        resolver: LEDColorResolver,
        count: Int,
        brightnessLevels: Int,
        scheme: ColorScheme
    ) {
        let safeCount = max(1, count)
        let safeLevels = max(2, brightnessLevels)
        let baseNS = scheme == .dark ? NSColor.white : NSColor.black
        baseFill = baseNS.withAlphaComponent(0.10).cgColor
        dividerFill = baseNS.withAlphaComponent(0.12).cgColor

        statusFill = (0..<safeLevels).map { level in
            resolver.statusLightNSColor(level: level)
                .withAlphaComponent(Self.opacity(for: level, levels: safeLevels, scheme: scheme))
                .cgColor
        }
        statusStroke = (0..<safeLevels).map { level in
            let opacity = min(0.50, Self.opacity(for: level, levels: safeLevels, scheme: scheme) * 0.55)
            return resolver.statusLightStrokeNSColor(level: level)
                .withAlphaComponent(opacity)
                .cgColor
        }

        ledFill = (0..<safeCount).map { index in
            (0..<safeLevels).map { level in
                resolver.volumeLEDNSColor(index: index, count: safeCount, level: level)
                    .withAlphaComponent(Self.opacity(for: level, levels: safeLevels, scheme: scheme))
                    .cgColor
            }
        }
        ledStroke = (0..<safeCount).map { index in
            (0..<safeLevels).map { level in
                let opacity = min(0.50, Self.opacity(for: level, levels: safeLevels, scheme: scheme) * 0.55)
                return resolver.volumeLEDStrokeNSColor(index: index, count: safeCount, level: level)
                    .withAlphaComponent(opacity)
                    .cgColor
            }
        }

        var hasher = Hasher()
        hasher.combine(safeCount)
        hasher.combine(safeLevels)
        Self.append(baseFill, to: &hasher)
        Self.append(dividerFill, to: &hasher)
        (statusFill + statusStroke).forEach { Self.append($0, to: &hasher) }
        ledFill.flatMap { $0 }.forEach { Self.append($0, to: &hasher) }
        ledStroke.flatMap { $0 }.forEach { Self.append($0, to: &hasher) }
        signature = hasher.finalize()
    }

    private static func opacity(for level: Int, levels: Int, scheme: ColorScheme) -> CGFloat {
        guard level > 0, levels > 1 else { return 0 }
        let t = CGFloat(level) / CGFloat(levels - 1)
        if scheme == .dark {
            return 0.08 + pow(t, 1.55) * 0.92
        }
        return 0.06 + pow(t, 1.65) * 0.94
    }

    private static func append(_ color: CGColor, to hasher: inout Hasher) {
        let nsColor = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB)
        hasher.combine(Int((nsColor?.redComponent ?? 0) * 1_000))
        hasher.combine(Int((nsColor?.greenComponent ?? 0) * 1_000))
        hasher.combine(Int((nsColor?.blueComponent ?? 0) * 1_000))
        hasher.combine(Int((nsColor?.alphaComponent ?? 0) * 1_000))
    }
}

private struct LiveLedMeterLayerRepresentable: NSViewRepresentable {
    let provider: LEDMeterServiceProvider
    let configuration: LiveLedMeterLayerConfiguration

    func makeNSView(context: Context) -> LiveLedMeterLayerHostView {
        let view = LiveLedMeterLayerHostView()
        view.configure(configuration, provider: provider)
        return view
    }

    func updateNSView(_ nsView: LiveLedMeterLayerHostView, context: Context) {
        nsView.configure(configuration, provider: provider)
    }

    static func dismantleNSView(_ nsView: LiveLedMeterLayerHostView, coordinator: ()) {
        nsView.unbind()
    }
}

@MainActor
private final class LiveLedMeterLayerHostView: NSView {
    private let rootLayer = CALayer()
    private var statusBaseLayer: CAShapeLayer?
    private var statusFillLayer: CAShapeLayer?
    private var statusStrokeLayer: CAShapeLayer?
    private let dividerLayer = CALayer()
    private var ledBaseLayers: [CAShapeLayer] = []
    private var ledFillLayers: [CAShapeLayer] = []
    private var ledStrokeLayers: [CAShapeLayer] = []

    private weak var provider: LEDMeterServiceProvider?
    private var consumerID: UUID?
    private var hasSession = false
    private var configuration: LiveLedMeterLayerConfiguration?
    private var lastColorSignature: Int?
    private var currentBrightnessStates: [Int] = []
    private var currentStatusLevel = 0
    private var breathTimer: Timer?

    private let breathHoldTime: Double = 0.32
    private let peakHoldTime: Double = 0.60
    private let zeroHoldTime: Double = 0.40

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        rootLayer.masksToBounds = false
        layer?.addSublayer(rootLayer)
        disableActions(rootLayer)
        disableActions(dividerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            unbind()
        }
    }

    func configure(
        _ configuration: LiveLedMeterLayerConfiguration,
        provider: LEDMeterServiceProvider
    ) {
        if self.provider !== provider {
            unbind()
            self.provider = provider
        }

        let countChanged = self.configuration?.ledCount != configuration.ledCount
            || self.configuration?.brightnessLevels != configuration.brightnessLevels
        let geometryChanged = self.configuration?.dotSize != configuration.dotSize
            || self.configuration?.spacing != configuration.spacing

        self.configuration = configuration

        if countChanged {
            rebuildLayers()
        }
        if countChanged || lastColorSignature != configuration.colors.signature {
            lastColorSignature = configuration.colors.signature
            applyColors()
        }
        if geometryChanged {
            needsLayout = true
        }

        syncBindingIfPossible()
        provider.updatePlaybackState(isPlaying: configuration.isPlaying)
        updateBreathTimer()
    }

    func unbind() {
        breathTimer?.invalidate()
        breathTimer = nil

        if let consumerID {
            provider?.removeFrameConsumer(consumerID)
            self.consumerID = nil
        }
        if hasSession {
            provider?.releaseSession()
            hasSession = false
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            unbind()
        } else {
            syncBindingIfPossible()
            updateBreathTimer()
        }
    }

    override func layout() {
        super.layout()
        guard let configuration else { return }
        rootLayer.frame = bounds

        let dotSize = configuration.dotSize
        let spacing = configuration.spacing
        let centerY = bounds.midY
        var x = dotSize * 0.5

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        layoutCircleLayers(
            [statusBaseLayer, statusFillLayer, statusStrokeLayer].compactMap { $0 },
            center: CGPoint(x: x, y: centerY),
            size: dotSize
        )

        x += dotSize * 0.5 + spacing
        dividerLayer.frame = CGRect(
            x: x,
            y: centerY - dotSize * 0.30,
            width: 1,
            height: dotSize * 0.60
        )

        x += 1 + spacing + dotSize * 0.5
        for index in 0..<ledBaseLayers.count {
            let center = CGPoint(
                x: x + CGFloat(index) * (dotSize + spacing),
                y: centerY
            )
            layoutCircleLayers(
                [ledBaseLayers[index], ledFillLayers[index], ledStrokeLayers[index]],
                center: center,
                size: dotSize
            )
        }

        CATransaction.commit()
    }

    private func syncBindingIfPossible() {
        guard window != nil, let provider else { return }
        if !hasSession {
            provider.acquireSession()
            hasSession = true
        }
        if consumerID == nil {
            consumerID = provider.addFrameConsumer { [weak self] led, audio in
                self?.applyFrame(led: led, audio: audio)
            }
        }
    }

    private func rebuildLayers() {
        rootLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        ledBaseLayers.removeAll(keepingCapacity: false)
        ledFillLayers.removeAll(keepingCapacity: false)
        ledStrokeLayers.removeAll(keepingCapacity: false)

        let statusBase = makeCircleLayer()
        let statusFill = makeCircleLayer()
        let statusStroke = makeCircleLayer(isStroke: true)
        statusBaseLayer = statusBase
        statusFillLayer = statusFill
        statusStrokeLayer = statusStroke
        rootLayer.addSublayer(statusBase)
        rootLayer.addSublayer(statusFill)
        rootLayer.addSublayer(statusStroke)

        rootLayer.addSublayer(dividerLayer)

        let count = max(1, configuration?.ledCount ?? AppSettings.shared.ledCount)
        for _ in 0..<count {
            let base = makeCircleLayer()
            let fill = makeCircleLayer()
            let stroke = makeCircleLayer(isStroke: true)
            ledBaseLayers.append(base)
            ledFillLayers.append(fill)
            ledStrokeLayers.append(stroke)
            rootLayer.addSublayer(base)
            rootLayer.addSublayer(fill)
            rootLayer.addSublayer(stroke)
        }

        currentBrightnessStates = Array(repeating: 0, count: count)
        currentStatusLevel = max(0, (configuration?.brightnessLevels ?? 2) - 1)
        needsLayout = true
    }

    private func makeCircleLayer(isStroke: Bool = false) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = isStroke ? NSColor.clear.cgColor : NSColor.clear.cgColor
        layer.strokeColor = isStroke ? NSColor.clear.cgColor : nil
        layer.lineWidth = isStroke ? 0.7 : 0
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        disableActions(layer)
        return layer
    }

    private func layoutCircleLayers(_ layers: [CAShapeLayer], center: CGPoint, size: CGFloat) {
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let path = CGPath(ellipseIn: bounds, transform: nil)
        for layer in layers {
            layer.bounds = bounds
            layer.position = center
            layer.path = path
        }
    }

    private func applyFrame(led: LEDMeterMetrics, audio: AudioMetrics) {
        guard let configuration else { return }
        let nextStates = brightnessStates(led: led, audio: audio, configuration: configuration)
        guard nextStates != currentBrightnessStates else { return }
        currentBrightnessStates = nextStates
        applyLEDLevels(nextStates)
    }

    private func brightnessStates(
        led: LEDMeterMetrics,
        audio: AudioMetrics,
        configuration: LiveLedMeterLayerConfiguration
    ) -> [Int] {
        if !led.leds.isEmpty {
            return (0..<configuration.ledCount).map { index in
                let value = index < led.leds.count ? Double(led.leds[index]) : 0
                return brightnessState(for: value, levels: configuration.brightnessLevels)
            }
        }

        let centerIndex = configuration.ledCount / 2
        let ledsFromCenterToEdge = configuration.ledCount / 2 + 1
        let totalSlots = ledsFromCenterToEdge * configuration.brightnessLevels
        let currentSlot = Double(max(0, min(1, audio.smoothedLevel))) * Double(totalSlots)
        return (0..<configuration.ledCount).map { index in
            let distanceFromCenter = abs(index - centerIndex)
            let ledStartSlot = Double(distanceFromCenter * configuration.brightnessLevels)
            if currentSlot < ledStartSlot {
                return 0
            } else if currentSlot >= ledStartSlot + Double(configuration.brightnessLevels) {
                return configuration.brightnessLevels - 1
            }
            return min(configuration.brightnessLevels - 1, Int(currentSlot - ledStartSlot))
        }
    }

    private func brightnessState(for value: Double, levels: Int) -> Int {
        let clamped = max(0, min(1, value))
        let step = 1.0 / Double(max(1, levels - 1))
        return min(levels - 1, Int(round(clamped / step)))
    }

    private func applyColors() {
        guard let configuration else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        statusBaseLayer?.fillColor = configuration.colors.baseFill
        dividerLayer.backgroundColor = configuration.colors.dividerFill
        for layer in ledBaseLayers {
            layer.fillColor = configuration.colors.baseFill
        }
        CATransaction.commit()

        let statusLevel = currentStatusLevel
        currentStatusLevel = -1
        applyStatusLevel(statusLevel)
        applyLEDLevels(currentBrightnessStates)
    }

    private func applyStatusLevel(_ level: Int) {
        guard let configuration else { return }
        let safeLevel = min(max(0, level), configuration.brightnessLevels - 1)
        guard safeLevel != currentStatusLevel || statusFillLayer?.fillColor == nil else { return }
        currentStatusLevel = safeLevel
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        statusFillLayer?.fillColor = configuration.colors.statusFill[safeLevel]
        statusStrokeLayer?.strokeColor = configuration.colors.statusStroke[safeLevel]
        CATransaction.commit()
    }

    private func applyLEDLevels(_ states: [Int]) {
        guard let configuration else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<min(states.count, ledFillLayers.count) {
            let level = min(max(0, states[index]), configuration.brightnessLevels - 1)
            ledFillLayers[index].fillColor = configuration.colors.ledFill[index][level]
            ledStrokeLayers[index].strokeColor = configuration.colors.ledStroke[index][level]
        }
        CATransaction.commit()
    }

    private func updateBreathTimer() {
        guard let configuration else { return }
        if configuration.isPlaying, window != nil {
            if breathTimer == nil {
                let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.tickBreath()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                breathTimer = timer
            }
        } else {
            breathTimer?.invalidate()
            breathTimer = nil
            applyStatusLevel(max(0, configuration.brightnessLevels - 1))
        }
    }

    private func tickBreath() {
        guard let configuration, configuration.isPlaying else { return }
        applyStatusLevel(breathStep(at: Date(), levels: configuration.brightnessLevels))
    }

    private func breathStep(at date: Date, levels: Int) -> Int {
        guard levels > 1 else { return 0 }
        let maxStep = levels - 1
        let riseDuration = Double(maxStep) * breathHoldTime
        let fallDuration = Double(maxStep) * breathHoldTime
        let cycleDuration = riseDuration + peakHoldTime + fallDuration + zeroHoldTime
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycleDuration)

        if t < riseDuration {
            return min(maxStep, Int(t / breathHoldTime))
        } else if t < riseDuration + peakHoldTime {
            return maxStep
        } else if t < riseDuration + peakHoldTime + fallDuration {
            let dt = t - (riseDuration + peakHoldTime)
            return max(1, maxStep - Int(dt / breathHoldTime))
        }
        return 1
    }

    private func disableActions(_ layer: CALayer) {
        layer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull(),
            "path": NSNull(),
            "backgroundColor": NSNull(),
            "fillColor": NSNull(),
            "strokeColor": NSNull(),
            "opacity": NSNull(),
        ]
    }
}

private struct LedMeterLifecycleModifier: ViewModifier {
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider
    @State private var hasActiveSession = false

    let isActive: Bool
    let isPlaying: Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                syncSession()
            }
            .onDisappear {
                releaseSession()
            }
            .onChange(of: isActive) { _, _ in
                syncSession()
            }
            .onChange(of: isPlaying) { _, newValue in
                ledMeterProvider.updatePlaybackState(isPlaying: newValue)
            }
    }

    private func syncSession() {
        ledMeterProvider.updatePlaybackState(isPlaying: isPlaying)
        if isActive {
            guard !hasActiveSession else { return }
            ledMeterProvider.acquireSession()
            hasActiveSession = true
        } else {
            releaseSession()
        }
    }

    private func releaseSession() {
        guard hasActiveSession else { return }
        ledMeterProvider.releaseSession()
        hasActiveSession = false
    }
}

extension View {
    func ledMeterLifecycle(isActive: Bool = true, isPlaying: Bool) -> some View {
        modifier(LedMeterLifecycleModifier(isActive: isActive, isPlaying: isPlaying))
    }
}

// MARK: - Preview

#Preview("LED Meter - 11 LEDs") {
    VStack(spacing: 20) {
        ForEach([0.0, 0.15, 0.3, 0.5, 0.7, 0.85, 1.0], id: \.self) { level in
            HStack {
                Text(String(format: "%.0f%%", level * 100))
                    .frame(width: 40)
                    .font(.caption)
                    .foregroundStyle(.white)

                LedMeterView(level: level, dotSize: 10, spacing: 5, isPlaying: true)
            }
        }
    }
    .padding(30)
    .background(Color.black.opacity(0.8))
}

#Preview("LED Meter - Light Mode") {
    VStack(spacing: 20) {
        LedMeterView(level: 0.0, dotSize: 10, spacing: 5, isPlaying: true)
        LedMeterView(level: 0.5, dotSize: 10, spacing: 5, isPlaying: true)
        LedMeterView(level: 1.0, dotSize: 10, spacing: 5, isPlaying: true)
    }
    .padding(30)
    .background(Color.gray.opacity(0.2))
    .preferredColorScheme(.light)
}

#Preview("LED Meter - Animated") {
    struct AnimatedPreview: View {
        @State private var level: Double = 0

        var body: some View {
            VStack(spacing: 30) {
                LedMeterView(level: level, dotSize: 10, spacing: 5, isPlaying: true)

                Slider(value: $level, in: 0...1)
                    .frame(width: 250)

                Text(String(format: "Level: %.2f", level))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(30)
            .background(.ultraThinMaterial)
        }
    }

    return AnimatedPreview()
}
