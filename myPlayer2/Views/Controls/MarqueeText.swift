//
//  MarqueeText.swift
//  myPlayer2
//
//  Scrolls only when text overflows current available width.
//  OPTIMIZED: Only animates when shouldAnimate is true (playing/hovered rows).
//

import AppKit
import SwiftUI

struct MarqueeText: View {
    enum Style {
        case body
        case subheadline
        case caption
        case custom(fontSize: CGFloat)  // For fullscreen mode with scaled sizes
    }

    let text: String
    let style: Style
    let fontWeight: Font.Weight
    let color: Color
    let shouldAnimate: Bool  // NEW: Only animate when true (playing/hovered)
    let enablesContentTransition: Bool

    var pauseAtStart: TimeInterval = 3.0
    var pointsPerSecond: CGFloat = 28.0
    var minOverflowToScroll: CGFloat = 2.0

    init(
        text: String,
        style: Style = .body,
        fontWeight: Font.Weight = .regular,
        color: Color = .primary,
        shouldAnimate: Bool = true,  // Default to animate for backward compatibility
        enablesContentTransition: Bool = false
    ) {
        self.text = text
        self.style = style
        self.fontWeight = fontWeight
        self.color = color
        self.shouldAnimate = shouldAnimate
        self.enablesContentTransition = enablesContentTransition
    }

    /// Convenience initializer for custom font size (fullscreen mode)
    init(
        text: String,
        fontSize: CGFloat,
        fontWeight: Font.Weight = .regular,
        color: Color = .primary,
        shouldAnimate: Bool = true,
        enablesContentTransition: Bool = false
    ) {
        self.text = text
        self.style = .custom(fontSize: fontSize)
        self.fontWeight = fontWeight
        self.color = color
        self.shouldAnimate = shouldAnimate
        self.enablesContentTransition = enablesContentTransition
    }

    @State private var availableWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var cycleStart = Date()

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            let overflow = max(0, textWidth - width)
            let isActivelyScrolling = overflow > minOverflowToScroll && shouldAnimate

            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActivelyScrolling)) { timeline in
                label(isActivelyScrolling: isActivelyScrolling, date: timeline.date, overflow: overflow)
            }
            .frame(width: width, alignment: .leading)
            .clipped()
            .onAppear {
                syncAvailableWidth(width)
                refreshTextWidth()
            }
            .onChange(of: width) { _, newWidth in
                syncAvailableWidth(newWidth)
            }
        }
        .frame(height: max(1, nsFont.ascender - nsFont.descender + nsFont.leading))
        .onChange(of: text) { _, _ in
            refreshTextWidth()
        }
        .onChange(of: fontWeight) { _, _ in
            refreshTextWidth()
        }
    }

    @ViewBuilder
    private func label(isActivelyScrolling: Bool, date: Date, overflow: CGFloat) -> some View {
        baseLabel
            .truncationMode(.tail)
            .fixedSize(horizontal: isActivelyScrolling, vertical: false)
            .offset(x: isActivelyScrolling ? offset(at: date, overflow: overflow) : 0)
    }

    @ViewBuilder
    private var baseLabel: some View {
        let label = Text(text)
            .font(swiftUIFont)
            .fontWeight(fontWeight)
            .foregroundStyle(color)
            .lineLimit(1)
        if enablesContentTransition {
            label
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: text)
        } else {
            label
        }
    }

    private var swiftUIFont: Font {
        switch style {
        case .body:
            return .body
        case .subheadline:
            return .subheadline
        case .caption:
            return .caption
        case .custom(fontSize: let size):
            return .system(size: size)
        }
    }

    private var nsFont: NSFont {
        let textStyle: NSFont.TextStyle
        let pointSize: CGFloat
        switch style {
        case .body:
            textStyle = .body
            pointSize = NSFont.preferredFont(forTextStyle: textStyle).pointSize
        case .subheadline:
            textStyle = .subheadline
            pointSize = NSFont.preferredFont(forTextStyle: textStyle).pointSize
        case .caption:
            textStyle = .caption1
            pointSize = NSFont.preferredFont(forTextStyle: textStyle).pointSize
        case .custom(fontSize: let size):
            pointSize = size
        }
        return NSFont.systemFont(ofSize: pointSize, weight: nsWeight)
    }

    private var nsWeight: NSFont.Weight {
        switch fontWeight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    private func refreshTextWidth() {
        let attributes: [NSAttributedString.Key: Any] = [.font: nsFont]
        textWidth = ceil((text as NSString).size(withAttributes: attributes).width)
        cycleStart = Date()
    }

    private func syncAvailableWidth(_ width: CGFloat) {
        guard abs(availableWidth - width) > 0.5 else { return }
        availableWidth = width
        cycleStart = Date()
    }

    private func offset(at date: Date, overflow: CGFloat) -> CGFloat {
        let travelDuration = TimeInterval(overflow / max(10, pointsPerSecond))
        let holdAtEnd: TimeInterval = 0.35
        let cycleDuration = pauseAtStart + travelDuration + holdAtEnd
        guard cycleDuration > 0 else { return 0 }

        let elapsed = date.timeIntervalSince(cycleStart)
        let t = elapsed.truncatingRemainder(dividingBy: cycleDuration)

        if t < pauseAtStart { return 0 }
        if t < pauseAtStart + travelDuration {
            let progress = (t - pauseAtStart) / travelDuration
            return -overflow * progress
        }
        return -overflow
    }
}
