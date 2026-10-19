// SeamlessMarqueeText.swift
// myPlayer2
//
// Seamless looping marquee for title/artist text.
// Core Animation owns a linear loop and synchronized feathered edges.
// Renders two text copies so the loop reset is invisible.
//
// Measures rendered SwiftUI text with a hidden fixed-size copy so overflow
// detection matches the actual row rendering.

import AppKit
import MotionKit
import QuartzCore
import SwiftUI

struct SeamlessMarqueeText: View {

    enum Style: Equatable {
        case body
        case subheadline
        case caption
        case custom(fontSize: CGFloat)
    }

    let text: String
    let style: Style
    let fontWeight: Font.Weight
    let color: Color

    var gap: CGFloat = 40.0            // points between copy 1 and copy 2
    var speed: CGFloat = 24.0          // points per second
    var pauseDuration: TimeInterval = 5.0
    var shouldAnimate: Bool = true
    var enablesContentTransition: Bool = false


    @State private var textWidth: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy

    private var motionPolicy: MotionPolicy {
        configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
    }


    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            contentView(width: width)
                .frame(width: width, alignment: .leading)
                .clipped()
        }
        .frame(height: lineHeight)
        .background(textMeasurementView)
        .onPreferenceChange(MarqueeTextWidthPreferenceKey.self) { width in
            syncMeasuredTextWidth(width)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }

    // MARK: - Content view

    @ViewBuilder
    private func contentView(width: CGFloat) -> some View {
        let isMarquee = shouldAnimate && motionPolicy == .full && width > 0 && (textWidth - width) > 2.0
        if isMarquee {
            MarqueeLayerHost(
                content: marqueeCopies,
                revision: MarqueeContentRevision(
                    text: text, style: style, fontWeight: fontWeight, color: color,
                    textWidth: textWidth, lineHeight: lineHeight, gap: gap,
                    enablesContentTransition: enablesContentTransition,
                    colorScheme: colorScheme, motionTokens: motionTokens, motionPolicy: motionPolicy
                ),
                configuration: MarqueeLayoutConfiguration(
                    textWidth: textWidth, gap: gap, speed: speed, pauseDuration: pauseDuration
                )
            )
        } else {
            textLabel
                .truncationMode(.tail)
        }
    }

    // MARK: - Text rendering (shared by both modes)

    private var baseTextLabel: some View {
        Text(text)
            .font(swiftUIFont)
            .fontWeight(fontWeight)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    @ViewBuilder
    private var textLabel: some View {
        if enablesContentTransition {
            baseTextLabel
                .contentTransition(.interpolate)
                .motionAnimation(.contentReplacement, value: text)
        } else {
            baseTextLabel
        }
    }

    private var marqueeCopies: some View {
        HStack(spacing: gap) {
            textLabel
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: textWidth, alignment: .leading)
            textLabel
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: textWidth, alignment: .leading)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: lineHeight)
        .environment(\.colorScheme, colorScheme)
        .environment(\.motionTokens, motionTokens)
        .environment(\.motionPolicy, motionPolicy)
        .accessibilityHidden(true)
    }

    private var textMeasurementView: some View {
        // Measure the final text, independently of the replacement transition.
        baseTextLabel
            .fixedSize(horizontal: true, vertical: false)
            .hidden()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MarqueeTextWidthPreferenceKey.self,
                        value: ceil(proxy.size.width)
                    )
                }
            )
    }

    // MARK: - Measurement

    private func syncMeasuredTextWidth(_ width: CGFloat) {
        guard abs(textWidth - width) > 0.5 else { return }
        textWidth = width
    }

    // MARK: - Font helpers

    private var swiftUIFont: Font {
        switch style {
        case .body:            return .body
        case .subheadline:     return .subheadline
        case .caption:         return .caption
        case .custom(let sz):  return .system(size: sz)
        }
    }

    private var nsFont: NSFont {
        switch style {
        case .body:
            return NSFont.systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                weight: nsWeight)
        case .subheadline:
            return NSFont.systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: nsWeight)
        case .caption:
            return NSFont.systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                weight: nsWeight)
        case .custom(let sz):
            return NSFont.systemFont(ofSize: sz, weight: nsWeight)
        }
    }

    private var nsWeight: NSFont.Weight {
        switch fontWeight {
        case .ultraLight: return .ultraLight
        case .thin:       return .thin
        case .light:      return .light
        case .regular:    return .regular
        case .medium:     return .medium
        case .semibold:   return .semibold
        case .bold:       return .bold
        case .heavy:      return .heavy
        case .black:      return .black
        default:          return .regular
        }
    }

    private var lineHeight: CGFloat {
        let f = nsFont
        return max(1, f.ascender - f.descender + f.leading)
    }
}

/// A compositor-owned loop: pause at the readable start, then travel at a fixed
/// points-per-second rate. The two copies occupy identical frames at the seam.
struct SeamlessMarqueeTiming {
    let distance: CGFloat
    let pauseDuration: TimeInterval
    let travelDuration: TimeInterval
    let fadeDuration: TimeInterval

    var duration: TimeInterval { pauseDuration + travelDuration }

    init(distance: CGFloat, speed: CGFloat, pauseDuration: TimeInterval, fadeWidth: CGFloat) {
        self.distance = distance
        self.pauseDuration = max(0, pauseDuration)
        let rate = max(1, speed)
        travelDuration = Double(distance / rate)
        fadeDuration = min(Double(fadeWidth / rate), travelDuration / 2)
    }

    func scrollAnimation() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        if pauseDuration > 0 {
            animation.values = [0, 0, -distance]
            animation.keyTimes = [0, NSNumber(value: pauseDuration / duration), 1]
        } else {
            animation.values = [0, -distance]
            animation.keyTimes = [0, 1]
        }
        configure(animation)
        return animation
    }

    func fadeAnimation(restingColors: [CGColor], movingColors: [CGColor]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "colors")
        var colors = [restingColors, movingColors, movingColors, restingColors]
        var times = [0, (pauseDuration + fadeDuration) / duration, (duration - fadeDuration) / duration, 1]
        if pauseDuration > 0 {
            colors.insert(restingColors, at: 1)
            times.insert(pauseDuration / duration, at: 1)
        }
        animation.values = colors
        animation.keyTimes = times.map { NSNumber(value: $0) }
        configure(animation)
        return animation
    }

    private func configure(_ animation: CAKeyframeAnimation) {
        // Marquee motion is a continuous linear loop, outside MotionKit springs.
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        let linear = CAMediaTimingFunction(name: .linear)
        animation.timingFunction = linear
        animation.timingFunctions = Array(repeating: linear, count: (animation.keyTimes?.count ?? 1) - 1)
    }
}

private struct MarqueeContentRevision: Equatable {
    let text: String
    let style: SeamlessMarqueeText.Style
    let fontWeight: Font.Weight
    let color: Color
    let textWidth: CGFloat
    let lineHeight: CGFloat
    let gap: CGFloat
    let enablesContentTransition: Bool
    let colorScheme: ColorScheme
    let motionTokens: MotionTokens
    let motionPolicy: MotionPolicy
}

private struct MarqueeLayoutConfiguration: Equatable {
    let textWidth: CGFloat
    let gap: CGFloat
    let speed: CGFloat
    let pauseDuration: TimeInterval

    var contentWidth: CGFloat { textWidth * 2 + gap }
    var distance: CGFloat { textWidth + gap }
}

/// SwiftUI still renders the text and its content transition. AppKit only owns
/// the clipping viewport, mask and translation, with no per-frame state updates.
private struct MarqueeLayerHost<Content: View>: NSViewRepresentable {
    let content: Content
    let revision: MarqueeContentRevision
    let configuration: MarqueeLayoutConfiguration

    func makeNSView(context: Context) -> MarqueeLayerView<Content> {
        MarqueeLayerView(content: content, revision: revision, configuration: configuration)
    }

    func updateNSView(_ nsView: MarqueeLayerView<Content>, context: Context) {
        nsView.update(content: content, revision: revision, configuration: configuration)
    }

    static func dismantleNSView(_ nsView: MarqueeLayerView<Content>, coordinator: ()) {
        nsView.stopScrolling()
    }
}

private final class MarqueeLayerView<Content: View>: NSView {
    private let contentView = NSView()
    private let hostingView: NSHostingView<Content>
    private let edgeMask = CAGradientLayer()
    private var revision: MarqueeContentRevision
    private var configuration: MarqueeLayoutConfiguration
    private var animatedSize: CGSize = .zero
    private var needsRestart = true

    private let scrollKey = "marquee.translation"
    private let fadeKey = "marquee.leadingFade"
    private let opaqueColor = CGColor(gray: 1, alpha: 1)
    private let transparentColor = CGColor(gray: 1, alpha: 0)
    private var restingColors: [CGColor] { [opaqueColor, opaqueColor, opaqueColor, transparentColor] }
    private var movingColors: [CGColor] { [transparentColor, opaqueColor, opaqueColor, transparentColor] }

    override var isFlipped: Bool { true }

    init(content: Content, revision: MarqueeContentRevision, configuration: MarqueeLayoutConfiguration) {
        hostingView = NSHostingView(rootView: content)
        self.revision = revision
        self.configuration = configuration
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.mask = edgeMask
        edgeMask.startPoint = CGPoint(x: 0, y: 0.5)
        edgeMask.endPoint = CGPoint(x: 1, y: 0.5)
        edgeMask.colors = restingColors
        contentView.wantsLayer = true
        hostingView.sizingOptions = []
        contentView.addSubview(hostingView)
        addSubview(contentView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(content: Content, revision newRevision: MarqueeContentRevision, configuration newConfiguration: MarqueeLayoutConfiguration) {
        if revision != newRevision {
            needsRestart = needsRestart || revision.text != newRevision.text
                || revision.style != newRevision.style || revision.fontWeight != newRevision.fontWeight
            revision = newRevision
            hostingView.rootView = content
        }
        if configuration != newConfiguration {
            configuration = newConfiguration
            needsRestart = true
        }
        if needsRestart { needsLayout = true }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        contentView.frame = CGRect(x: 0, y: 0, width: configuration.contentWidth, height: bounds.height)
        hostingView.frame = contentView.bounds
        edgeMask.frame = bounds
        guard bounds.width > 0, bounds.height > 0 else {
            stopScrolling()
            return
        }
        let fadeWidth = min(12, bounds.width / 4)
        let edge = fadeWidth / bounds.width
        edgeMask.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]

        guard window != nil, !isHiddenOrHasHiddenAncestor else {
            stopScrolling()
            return
        }
        guard needsRestart || animatedSize != bounds.size else { return }
        stopScrolling()
        animatedSize = bounds.size
        needsRestart = false

        let timing = SeamlessMarqueeTiming(
            distance: configuration.distance, speed: configuration.speed,
            pauseDuration: configuration.pauseDuration, fadeWidth: fadeWidth
        )
        let scroll = timing.scrollAnimation()
        let fade = timing.fadeAnimation(restingColors: restingColors, movingColors: movingColors)
        // Convert the same clock instant into each layer's local time.
        let now = CACurrentMediaTime()
        if let scrollingLayer = contentView.layer {
            scroll.beginTime = scrollingLayer.convertTime(now, from: nil)
            scrollingLayer.add(scroll, forKey: scrollKey)
        }
        fade.beginTime = edgeMask.convertTime(now, from: nil)
        edgeMask.add(fade, forKey: fadeKey)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopScrolling()
        needsLayout = true
    }

    override func viewDidHide() {
        super.viewDidHide()
        stopScrolling()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        needsLayout = true
    }

    func stopScrolling() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView.layer?.removeAnimation(forKey: scrollKey)
        edgeMask.removeAnimation(forKey: fadeKey)
        edgeMask.colors = restingColors
        CATransaction.commit()
        needsRestart = true
    }
}

private struct MarqueeTextWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Convenience initializers (match current MarqueeText call sites)

extension SeamlessMarqueeText {
    /// fontSize-based initializer — used by FullscreenMiniPlayerView (scaled sizes).
    init(
        text: String,
        fontSize: CGFloat,
        fontWeight: Font.Weight = .regular,
        color: Color = .primary,
        gap: CGFloat = 40,
        speed: CGFloat = 24,
        pauseDuration: TimeInterval = 5,
        shouldAnimate: Bool = true,
        enablesContentTransition: Bool = false
    ) {
        self.text = text
        self.style = .custom(fontSize: fontSize)
        self.fontWeight = fontWeight
        self.color = color
        self.gap = gap
        self.speed = speed
        self.pauseDuration = pauseDuration
        self.shouldAnimate = shouldAnimate
        self.enablesContentTransition = enablesContentTransition
    }
}

// MARK: - Preview

#Preview("SeamlessMarqueeText – Animated") {
    VStack(alignment: .leading, spacing: 20) {
        Group {
            Text("Short (no scroll)").font(.caption).foregroundStyle(.secondary)
            SeamlessMarqueeText(
                text: "Short title",
                style: .body,
                fontWeight: .medium,
                color: .primary
            )
            .frame(width: 200)
            .border(Color.red.opacity(0.3))
        }
        Group {
            Text("Long — scrolls seamlessly, pauses 5s, loops").font(.caption).foregroundStyle(.secondary)
            SeamlessMarqueeText(
                text: "A very long title that definitely overflows its container width here",
                style: .body,
                fontWeight: .medium,
                color: .primary,
                speed: 30
            )
            .frame(width: 200)
            .border(Color.red.opacity(0.3))
        }
        Group {
            Text("shouldAnimate: false — must stay static").font(.caption).foregroundStyle(.secondary)
            SeamlessMarqueeText(
                text: "A very long title that definitely overflows but must not scroll",
                style: .body,
                fontWeight: .medium,
                color: .primary,
                shouldAnimate: false
            )
            .frame(width: 200)
            .border(Color.red.opacity(0.3))
        }
    }
    .padding()
    .frame(width: 320, height: 240)
}
