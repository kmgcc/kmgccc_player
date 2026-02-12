//
//  MarqueeText.swift
//  myPlayer2
//
//  Single-line text that scrolls when overflowed.
//

import SwiftUI

struct MarqueeText: View {
    let text: String
    let font: Font
    let fontWeight: Font.Weight
    let color: Color

    var pauseAtStart: TimeInterval = 3.0
    var pointsPerSecond: CGFloat = 28
    var minimumOverflowToScroll: CGFloat = 18

    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var cycleStart = Date()

    private var overflow: CGFloat {
        max(0, textWidth - containerWidth)
    }

    private var shouldScroll: Bool {
        containerWidth > 1 && textWidth > 1 && overflow > minimumOverflowToScroll
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if shouldScroll {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                    label
                        .offset(x: offset(at: timeline.date))
                }
            } else {
                label
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .onSizeChange { size in
            if abs(containerWidth - size.width) > 0.5 {
                containerWidth = size.width
                cycleStart = Date()
            }
        }
        .background(
            label
                .fixedSize(horizontal: true, vertical: false)
                .hidden()
                .onSizeChange { size in
                    if abs(textWidth - size.width) > 0.5 {
                        textWidth = size.width
                        cycleStart = Date()
                    }
                }
        )
        .onChange(of: text) { _, _ in
            cycleStart = Date()
        }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .fontWeight(fontWeight)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private func offset(at date: Date) -> CGFloat {
        let distance = overflow
        guard distance > 1 else { return 0 }

        let travelDuration = TimeInterval(distance / max(10, pointsPerSecond))
        let holdEnd: TimeInterval = 0.4
        let cycleDuration = pauseAtStart + travelDuration + holdEnd
        guard cycleDuration > 0 else { return 0 }

        let elapsed = date.timeIntervalSince(cycleStart)
        let t = elapsed.truncatingRemainder(dividingBy: cycleDuration)

        if t < pauseAtStart {
            return 0
        }

        if t < pauseAtStart + travelDuration {
            let progress = (t - pauseAtStart) / travelDuration
            return -distance * progress
        }

        return -distance
    }
}

private struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private extension View {
    func onSizeChange(_ action: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: SizePreferenceKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(SizePreferenceKey.self, perform: action)
    }
}
