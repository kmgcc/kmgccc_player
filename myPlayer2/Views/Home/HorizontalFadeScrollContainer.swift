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

import AppKit
import QuartzCore
import SwiftUI

struct HorizontalFadeScrollContainer<Content: View>: View {
    let spacing: CGFloat
    let fadeWidth: CGFloat
    let verticalPadding: CGFloat
    let leadingScrollPadding: CGFloat
    let trailingScrollPadding: CGFloat
    let showsEdgeFade: Bool
    let showsScrollButtons: Bool
    let scrollButtonLeadingInset: CGFloat
    let scrollButtonTrailingInset: CGFloat
    let onHorizontalScrollOffsetChange: ((CGFloat) -> Void)?
    let onScrollMetricsChange: ((CGFloat, CGFloat, CGFloat) -> Void)?
    @ViewBuilder var content: () -> Content

    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var scrollX: CGFloat = 0
    @State private var canScrollLeft = false
    @State private var canScrollRight = false
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var activeScrollEdge: HorizontalScrollEdge?
    @State private var nativeScrollView: NSScrollView?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.homeLiveResizeRendering) private var isLiveResizing

    init(
        spacing: CGFloat = 0,
        fadeWidth: CGFloat = 24,
        verticalPadding: CGFloat = 12,
        leadingScrollPadding: CGFloat = 16,
        trailingScrollPadding: CGFloat = 16,
        showsEdgeFade: Bool = true,
        showsScrollButtons: Bool = false,
        scrollButtonLeadingInset: CGFloat = 12,
        scrollButtonTrailingInset: CGFloat = 12,
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
        self.showsScrollButtons = showsScrollButtons
        self.scrollButtonLeadingInset = scrollButtonLeadingInset
        self.scrollButtonTrailingInset = scrollButtonTrailingInset
        self.onHorizontalScrollOffsetChange = onHorizontalScrollOffsetChange
        self.onScrollMetricsChange = onScrollMetricsChange
        self.content = content
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
            .background(
                HorizontalNativeScrollViewResolver { scrollView in
                    nativeScrollView = scrollView
                }
            )
            // Asymmetric scroll content padding lets callers align the first
            // item with the Home content left edge while still allowing items
            // to drift left/right under adjacent glass regions when scrolling.
            // Vertical padding keeps hover lift / soft shadows from clipping
            // at the ScrollView content rect.
            .padding(.leading, leadingScrollPadding)
            .padding(.trailing, trailingScrollPadding)
            .padding(.vertical, verticalPadding)
        }
        .scrollPosition($scrollPosition)
        .scrollClipDisabled(true)
        .modifier(
            HorizontalScrollMetricsModifier(
                isEnabled: needsScrollMetrics,
                tracksExactScrollOffset: needsExactScrollOffset,
                contentWidth: $contentWidth,
                viewportWidth: $viewportWidth,
                scrollX: $scrollX,
                canScrollLeft: $canScrollLeft,
                canScrollRight: $canScrollRight,
                onHorizontalScrollOffsetChange: onHorizontalScrollOffsetChange,
                onScrollMetricsChange: onScrollMetricsChange
            )
        )
        .mask(scrollFadeMask)
        .overlay {
            if effectiveShowsScrollButtons {
                HorizontalEdgeHoverTracker(
                    edgeActivationWidth: edgeActivationWidth,
                    leadingInset: scrollButtonLeadingInset,
                    trailingInset: scrollButtonTrailingInset,
                    canActivateLeading: canScrollLeft,
                    canActivateTrailing: canScrollRight
                ) { edge in
                    activeScrollEdge = edge
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            if showsLeftScrollButton {
                edgeScrollButton(systemImage: "chevron.left", direction: -1)
                    .padding(.leading, scrollButtonLeadingInset)
                    .transition(.opacity)
                    .onHover { hovering in
                        updateActiveScrollEdge(.leading, hovering: hovering)
                    }
            }
        }
        .overlay(alignment: .trailing) {
            if showsRightScrollButton {
                edgeScrollButton(systemImage: "chevron.right", direction: 1)
                    .padding(.trailing, scrollButtonTrailingInset)
                    .transition(.opacity)
                    .onHover { hovering in
                        updateActiveScrollEdge(.trailing, hovering: hovering)
                    }
            }
        }
        .animation(showsEdgeFade ? .easeOut(duration: 0.18) : nil, value: leftFadeOpacity)
        .animation(showsEdgeFade ? .easeOut(duration: 0.18) : nil, value: rightFadeOpacity)
        .animation(isLiveResizing ? nil : .easeOut(duration: 0.30), value: showsLeftScrollButton)
        .animation(isLiveResizing ? nil : .easeOut(duration: 0.30), value: showsRightScrollButton)
    }

    @ViewBuilder
    private var scrollFadeMask: some View {
        if showsEdgeFade {
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color.black.opacity(1 - leftFadeOpacity),
                        Color.black,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: fadeWidth)

                Rectangle()
                    .fill(Color.black)

                LinearGradient(
                    colors: [
                        Color.black,
                        Color.black.opacity(1 - rightFadeOpacity),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: fadeWidth)
            }
        } else {
            Rectangle()
                .fill(Color.black)
        }
    }

    private var needsScrollMetrics: Bool {
        !isLiveResizing
            && (showsEdgeFade
                || showsScrollButtons
                || onHorizontalScrollOffsetChange != nil
                || onScrollMetricsChange != nil)
    }

    private var needsExactScrollOffset: Bool {
        !isLiveResizing && (showsEdgeFade || onHorizontalScrollOffsetChange != nil || onScrollMetricsChange != nil)
    }

    private var effectiveShowsScrollButtons: Bool {
        showsScrollButtons && !isLiveResizing
    }

    private var showsLeftScrollButton: Bool {
        guard effectiveShowsScrollButtons, canScrollLeft, activeScrollEdge == .leading else {
            return false
        }
        return true
    }

    private var showsRightScrollButton: Bool {
        guard effectiveShowsScrollButtons, canScrollRight, activeScrollEdge == .trailing else {
            return false
        }
        return true
    }

    private var edgeActivationWidth: CGFloat {
        min(max(viewportWidth * 0.16, 96), 150)
    }

    private func updateActiveScrollEdge(_ edge: HorizontalScrollEdge, hovering: Bool) {
        if hovering {
            activeScrollEdge = edge
        } else if activeScrollEdge == edge {
            activeScrollEdge = nil
        }
    }

    private func edgeScrollButton(systemImage: String, direction: CGFloat) -> some View {
        Button {
            let currentX = nativeScrollView?.contentView.bounds.origin.x ?? scrollX
            let step = max(140, viewportWidth * 0.46)
            let target = min(max(currentX + step * direction, 0), maxScroll)
            scrollTo(target)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary.opacity(0.86))
                .frame(width: 32, height: 68)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .liquidGlassPill(
            colorScheme: colorScheme,
            accentColor: nil,
            materialStyle: .clear,
            isFloating: true
        )
        .help(direction < 0 ? "向左滚动" : "向右滚动")
    }

    private func scrollTo(_ target: CGFloat) {
        guard let scrollView = nativeScrollView,
              let documentView = scrollView.documentView
        else {
            withAnimation(.easeInOut(duration: 0.42)) {
                scrollPosition.scrollTo(x: target)
            }
            return
        }

        let clipView = scrollView.contentView
        let maxNativeX = max(0, documentView.bounds.width - clipView.bounds.width)
        let targetX = min(max(target, 0), maxNativeX)
        let targetOrigin = NSPoint(x: targetX, y: clipView.bounds.origin.y)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.44
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.00, 0.12, 1.00)
            clipView.animator().setBoundsOrigin(targetOrigin)
        } completionHandler: {
            Task { @MainActor in
                scrollView.reflectScrolledClipView(clipView)
            }
        }
    }
}

private struct ScrollMetrics: Equatable {
    var contentWidth: CGFloat
    var viewportWidth: CGFloat
    var offsetX: CGFloat
}

private enum HorizontalScrollEdge {
    case leading
    case trailing
}

private struct HorizontalNativeScrollViewResolver: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            onResolve(view.enclosingScrollView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.enclosingScrollView)
        }
    }
}

private struct HorizontalEdgeHoverTracker: NSViewRepresentable {
    let edgeActivationWidth: CGFloat
    let leadingInset: CGFloat
    let trailingInset: CGFloat
    let canActivateLeading: Bool
    let canActivateTrailing: Bool
    let onActiveEdgeChange: (HorizontalScrollEdge?) -> Void

    func makeNSView(context _: Context) -> EdgeHoverTrackingView {
        let view = EdgeHoverTrackingView()
        view.configure(
            edgeActivationWidth: edgeActivationWidth,
            leadingInset: leadingInset,
            trailingInset: trailingInset,
            canActivateLeading: canActivateLeading,
            canActivateTrailing: canActivateTrailing,
            onActiveEdgeChange: onActiveEdgeChange
        )
        return view
    }

    func updateNSView(_ nsView: EdgeHoverTrackingView, context _: Context) {
        nsView.configure(
            edgeActivationWidth: edgeActivationWidth,
            leadingInset: leadingInset,
            trailingInset: trailingInset,
            canActivateLeading: canActivateLeading,
            canActivateTrailing: canActivateTrailing,
            onActiveEdgeChange: onActiveEdgeChange
        )
    }
}

private final class EdgeHoverTrackingView: NSView {
    private var trackingArea: NSTrackingArea?
    private var edgeActivationWidth: CGFloat = 0
    private var leadingInset: CGFloat = 0
    private var trailingInset: CGFloat = 0
    private var canActivateLeading = false
    private var canActivateTrailing = false
    private var activeEdge: HorizontalScrollEdge?
    private var onActiveEdgeChange: ((HorizontalScrollEdge?) -> Void)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func configure(
        edgeActivationWidth: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat,
        canActivateLeading: Bool,
        canActivateTrailing: Bool,
        onActiveEdgeChange: @escaping (HorizontalScrollEdge?) -> Void
    ) {
        self.edgeActivationWidth = edgeActivationWidth
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        self.canActivateLeading = canActivateLeading
        self.canActivateTrailing = canActivateTrailing
        self.onActiveEdgeChange = onActiveEdgeChange

        if !canActivateLeading, activeEdge == .leading {
            setActiveEdge(nil)
        }
        if !canActivateTrailing, activeEdge == .trailing {
            setActiveEdge(nil)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        updateActiveEdge(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateActiveEdge(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        setActiveEdge(nil)
    }

    private func updateActiveEdge(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            setActiveEdge(nil)
            return
        }

        let leadingStart = leadingInset
        let leadingEnd = leadingStart + edgeActivationWidth
        if canActivateLeading, point.x >= leadingStart, point.x <= leadingEnd {
            setActiveEdge(.leading)
            return
        }

        let trailingEnd = bounds.width - trailingInset
        let trailingStart = trailingEnd - edgeActivationWidth
        if canActivateTrailing, point.x >= trailingStart, point.x <= trailingEnd {
            setActiveEdge(.trailing)
            return
        }

        setActiveEdge(nil)
    }

    private func setActiveEdge(_ edge: HorizontalScrollEdge?) {
        guard activeEdge != edge else { return }
        activeEdge = edge
        DispatchQueue.main.async { [onActiveEdgeChange] in
            onActiveEdgeChange?(edge)
        }
    }
}

private struct HorizontalScrollMetricsModifier: ViewModifier {
    let isEnabled: Bool
    let tracksExactScrollOffset: Bool
    @Binding var contentWidth: CGFloat
    @Binding var viewportWidth: CGFloat
    @Binding var scrollX: CGFloat
    @Binding var canScrollLeft: Bool
    @Binding var canScrollRight: Bool
    let onHorizontalScrollOffsetChange: ((CGFloat) -> Void)?
    let onScrollMetricsChange: ((CGFloat, CGFloat, CGFloat) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                    ScrollMetrics(
                        contentWidth: geo.contentSize.width,
                        viewportWidth: geo.containerSize.width,
                        offsetX: max(0, geo.contentOffset.x)
                    )
                } action: { _, newValue in
                    let didChangeSize =
                        contentWidth != newValue.contentWidth
                            || viewportWidth != newValue.viewportWidth
                    let newCanScrollLeft = newValue.offsetX > 8
                    let newCanScrollRight =
                        max(0, newValue.contentWidth - newValue.viewportWidth) - newValue.offsetX > 8
                    let didChangeEdgeAvailability =
                        canScrollLeft != newCanScrollLeft
                            || canScrollRight != newCanScrollRight
                    let shouldUpdateExactOffset = tracksExactScrollOffset && scrollX != newValue.offsetX
                    guard
                        didChangeSize
                            || shouldUpdateExactOffset
                            || didChangeEdgeAvailability
                    else { return }
                    contentWidth = newValue.contentWidth
                    viewportWidth = newValue.viewportWidth
                    canScrollLeft = newCanScrollLeft
                    canScrollRight = newCanScrollRight

                    if tracksExactScrollOffset {
                        scrollX = newValue.offsetX
                        if shouldUpdateExactOffset {
                            onHorizontalScrollOffsetChange?(newValue.offsetX)
                        }
                        onScrollMetricsChange?(
                            newValue.contentWidth,
                            newValue.viewportWidth,
                            newValue.offsetX
                        )
                    } else if didChangeEdgeAvailability {
                        scrollX = newValue.offsetX
                    }
                }
        } else {
            content
        }
    }
}
