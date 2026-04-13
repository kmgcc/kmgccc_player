// SeamlessMarqueeText.swift
// myPlayer2
//
// Seamless looping marquee for title/artist text.
// Drives animation via withAnimation(.linear) + async Task state machine.
// Renders two text copies so the loop reset is invisible.

import AppKit
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
    var speed: CGFloat = 40.0          // points per second
    var pauseDuration: TimeInterval = 5.0
    var shouldAnimate: Bool = true
    var enablesContentTransition: Bool = false

    // MARK: - Body (static only — animation wired in Tasks 2–3)

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            textLabel
                .truncationMode(.tail)
                .frame(width: width, alignment: .leading)
                .clipped()
        }
        .frame(height: lineHeight)
    }

    // MARK: - Text rendering (shared by static and marquee modes)

    @ViewBuilder
    private var textLabel: some View {
        let base = Text(text)
            .font(swiftUIFont)
            .fontWeight(fontWeight)
            .foregroundStyle(color)
            .lineLimit(1)
        if enablesContentTransition {
            base
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: text)
        } else {
            base
        }
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

// MARK: - Convenience initializers (match current MarqueeText call sites)

extension SeamlessMarqueeText {
    /// Style-based initializer — used by MiniPlayerView and TrackRowView.
    init(
        text: String,
        style: Style = .body,
        fontWeight: Font.Weight = .regular,
        color: Color = .primary,
        shouldAnimate: Bool = true,
        enablesContentTransition: Bool = false
    ) {
        self.text = text
        self.style = style
        self.fontWeight = fontWeight
        self.color = color
        self.shouldAnimate = shouldAnimate
        self.enablesContentTransition = enablesContentTransition
    }

    /// fontSize-based initializer — used by FullscreenMiniPlayerView (scaled sizes).
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
}

// MARK: - Preview

#Preview("SeamlessMarqueeText – Static scaffold") {
    VStack(alignment: .leading, spacing: 20) {
        Text("Short (should not scroll)").font(.caption).foregroundStyle(.secondary)
        SeamlessMarqueeText(
            text: "Short title",
            style: .body,
            fontWeight: .medium,
            color: .primary
        )
        .frame(width: 200)
        .border(Color.red.opacity(0.3))

        Text("Long (overflow, no scroll yet)").font(.caption).foregroundStyle(.secondary)
        SeamlessMarqueeText(
            text: "A very long title that definitely overflows its container width here",
            style: .body,
            fontWeight: .medium,
            color: .primary
        )
        .frame(width: 200)
        .border(Color.red.opacity(0.3))
    }
    .padding()
    .frame(width: 320, height: 160)
}
