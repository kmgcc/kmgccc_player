//
//  MarqueeText.swift
//  myPlayer2
//
//  Scrolls only when text overflows current available width.
//

import AppKit
import SwiftUI

struct MarqueeText: View {
    enum Style {
        case body
        case subheadline
        case caption
    }

    let text: String
    let style: Style
    let fontWeight: Font.Weight
    let color: Color

    var pauseAtStart: TimeInterval = 3.0
    var pointsPerSecond: CGFloat = 28.0
    var minOverflowToScroll: CGFloat = 2.0

    @State private var availableWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var cycleStart = Date()

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            let overflow = max(0, textWidth - width)
            let shouldScroll = overflow > minOverflowToScroll

            ZStack(alignment: .leading) {
                if shouldScroll {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                        scrollingLabel
                            .offset(x: offset(at: timeline.date, overflow: overflow))
                    }
                } else {
                    staticLabel
                }
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

    private var staticLabel: some View {
        Text(text)
            .font(swiftUIFont)
            .fontWeight(fontWeight)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var scrollingLabel: some View {
        Text(text)
            .font(swiftUIFont)
            .fontWeight(fontWeight)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var swiftUIFont: Font {
        switch style {
        case .body:
            return .body
        case .subheadline:
            return .subheadline
        case .caption:
            return .caption
        }
    }

    private var nsFont: NSFont {
        let textStyle: NSFont.TextStyle
        switch style {
        case .body:
            textStyle = .body
        case .subheadline:
            textStyle = .subheadline
        case .caption:
            textStyle = .caption1
        }
        let pointSize = NSFont.preferredFont(forTextStyle: textStyle).pointSize
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
