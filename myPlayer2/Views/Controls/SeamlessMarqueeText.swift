// SeamlessMarqueeText.swift
// myPlayer2
//
// Seamless looping marquee for title/artist text.
// Drives animation via withAnimation(.linear) + async Task state machine.
// Renders two text copies so the loop reset is invisible.
//
// Measurement risk: textWidth uses NSString.size(withAttributes: [.font: nsFont]).
// This assumes nsFont (NSFont.systemFont) matches SwiftUI's Text rendering exactly.
// If a visible seam appears at the loop boundary, replace measureTextWidth() with
// a hidden Text + background(GeometryReader) approach.

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

    // MARK: - State

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0     // loop sets this in Task 3; always 0 here

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            contentView(width: width)
                .frame(width: width, alignment: .leading)
                .clipped()
                .onAppear { syncContainerWidth(width) }
                .onChange(of: width) { _, newWidth in syncContainerWidth(newWidth) }
        }
        .frame(height: lineHeight)
        .onChange(of: text)          { _, _ in refreshAndRestart() }
        .onChange(of: style)         { _, _ in refreshAndRestart() }
        .onChange(of: fontWeight)    { _, _ in refreshAndRestart() }
        .onChange(of: gap)           { _, _ in refreshAndRestart() }
        .onChange(of: speed)         { _, _ in refreshAndRestart() }
        .onChange(of: pauseDuration) { _, _ in refreshAndRestart() }
        .onChange(of: shouldAnimate) { _, newVal in
            if newVal { refreshAndRestart() } else { stopLoop() }
        }
        .onDisappear {
            stopLoop()
        }
    }

    // MARK: - Content view

    @ViewBuilder
    private func contentView(width: CGFloat) -> some View {
        let isMarquee = shouldAnimate && (textWidth - width) > 2.0
        if isMarquee {
            HStack(spacing: gap) {
                textLabel
                textLabel
            }
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: offset)
        } else {
            textLabel
                .truncationMode(.tail)
        }
    }

    // MARK: - Text rendering (shared by both modes)

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

    // MARK: - Measurement

    private func syncContainerWidth(_ width: CGFloat) {
        guard abs(containerWidth - width) > 0.5 else { return }
        containerWidth = width
        refreshAndRestart()
    }

    private func measureTextWidth() {
        let attrs: [NSAttributedString.Key: Any] = [.font: nsFont]
        textWidth = ceil((text as NSString).size(withAttributes: attrs).width)
    }

    private func refreshAndRestart() {
        measureTextWidth()
        stopLoop()
        guard shouldAnimate, containerWidth > 0, textWidth > containerWidth + 2.0 else { return }
        startLoop()
    }

    // MARK: - Loop task stubs (implemented in Task 3)

    private func startLoop() { /* Task 3 */ }
    private func stopLoop()  { /* Task 3 */ }

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
