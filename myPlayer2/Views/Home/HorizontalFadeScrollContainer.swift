//
//  HorizontalFadeScrollContainer.swift
//  myPlayer2
//
//  Lightweight horizontal ScrollView with edge fades that appear only when
//  the content is wider than the viewport and the user has scrolled away
//  from the corresponding edge. Fades never block hit-testing.
//
//  The container supports asymmetric leading/trailing scroll content padding
//  so that callers (Albums / Artists rows) can place the first item at the
//  Home content left edge while still extending the scrollable area visually
//  beyond the normal Home content column.
//

import SwiftUI

struct HorizontalFadeScrollContainer<Content: View>: View {
    let spacing: CGFloat
    let fadeWidth: CGFloat
    let verticalPadding: CGFloat
    let leadingScrollPadding: CGFloat
    let trailingScrollPadding: CGFloat
    let showsEdgeFade: Bool
    let onHorizontalScrollOffsetChange: ((CGFloat) -> Void)?
    let onScrollMetricsChange: ((CGFloat, CGFloat, CGFloat) -> Void)?
    @ViewBuilder var content: () -> Content

    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var scrollX: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    init(
        spacing: CGFloat = 0,
        fadeWidth: CGFloat = 24,
        verticalPadding: CGFloat = 12,
        leadingScrollPadding: CGFloat = 16,
        trailingScrollPadding: CGFloat = 16,
        showsEdgeFade: Bool = true,
        onHorizontalScrollOffsetChange: ((CGFloat) -> Void)? = nil,
        onScrollMetricsChange: ((CGFloat, CGFloat, CGFloat) -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.spacing = spacing
        self.fadeWidth = fadeWidth
        self.verticalPadding = verticalPadding
        self.leadingScrollPadding = leadingScrollPadding
        self.trailingScrollPadding = trailingScrollPadding
        self.showsEdgeFade = showsEdgeFade
        self.onHorizontalScrollOffsetChange = onHorizontalScrollOffsetChange
        self.onScrollMetricsChange = onScrollMetricsChange
        self.content = content
    }

    private var fadeBaseColor: Color {
        // Match the page surface (NavigationSplitView detail column).
        Color(nsColor: .windowBackgroundColor)
    }

    private var maxScroll: CGFloat {
        max(0, contentWidth - viewportWidth)
    }

    private var isScrollable: Bool {
        contentWidth > viewportWidth + 0.5
    }

    /// Smooth ramp from 0 (at far-left) to 1 (after ~18px of scroll).
    private var leftFadeOpacity: Double {
        guard isScrollable else { return 0 }
        return min(1, max(0, Double(scrollX) / 18.0))
    }

    /// Smooth ramp from 1 (more content right) to 0 (at far-right).
    private var rightFadeOpacity: Double {
        guard isScrollable else { return 0 }
        let remaining = maxScroll - scrollX
        return min(1, max(0, Double(remaining) / 18.0))
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                content()
            }
            // Asymmetric scroll content padding lets callers align the first
            // item with the Home content left edge while still allowing items
            // to drift left/right under adjacent glass regions when scrolling.
            // Vertical padding keeps hover lift / soft shadows from clipping
            // at the ScrollView content rect.
            .padding(.leading, leadingScrollPadding)
            .padding(.trailing, trailingScrollPadding)
            .padding(.vertical, verticalPadding)
        }
        .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
            ScrollMetrics(
                contentWidth: geo.contentSize.width,
                viewportWidth: geo.containerSize.width,
                offsetX: max(0, geo.contentOffset.x)
            )
        } action: { _, newValue in
            contentWidth = newValue.contentWidth
            viewportWidth = newValue.viewportWidth
            scrollX = newValue.offsetX
            onHorizontalScrollOffsetChange?(newValue.offsetX)
            onScrollMetricsChange?(newValue.contentWidth, newValue.viewportWidth, newValue.offsetX)
        }
        .overlay(alignment: .leading) {
            if showsEdgeFade {
                LinearGradient(
                    colors: [fadeBaseColor, fadeBaseColor.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: fadeWidth)
                .frame(maxHeight: .infinity)
                .opacity(leftFadeOpacity)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            if showsEdgeFade {
                LinearGradient(
                    colors: [fadeBaseColor.opacity(0), fadeBaseColor],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: fadeWidth)
                .frame(maxHeight: .infinity)
                .opacity(rightFadeOpacity)
                .allowsHitTesting(false)
            }
        }
        .animation(showsEdgeFade ? .easeOut(duration: 0.18) : nil, value: leftFadeOpacity)
        .animation(showsEdgeFade ? .easeOut(duration: 0.18) : nil, value: rightFadeOpacity)
    }
}

private struct ScrollMetrics: Equatable {
    var contentWidth: CGFloat
    var viewportWidth: CGFloat
    var offsetX: CGFloat
}
