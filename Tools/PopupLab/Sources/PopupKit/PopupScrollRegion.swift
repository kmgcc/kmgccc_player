import SwiftUI

/// A scrolling viewport with edge-aware fading and an optional, compact action overlay.
public struct PopupScrollRegion<Content: View, Actions: View>: View {
    private let height: CGFloat?
    private let hasActions: Bool
    private let content: Content
    private let actions: Actions

    @Environment(\.popupStyle) private var style
    @Namespace private var coordinateSpace
    @State private var distances = ScrollDistances()
    @State private var actionsRect = CGRect.zero
    @State private var viewportHeight: CGFloat = 0

    public init(
        height: CGFloat? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.height = height
        self.content = content()
        self.actions = actions()
        self.hasActions = true
    }

    public init(height: CGFloat? = nil, @ViewBuilder content: () -> Content) where Actions == EmptyView {
        self.height = height
        self.content = content()
        self.actions = EmptyView()
        self.hasActions = false
    }

    public var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
                // This is end-of-document scroll room, rather than a reserved footer row.
                .padding(.bottom, scrollRoom)
        }
        .onScrollGeometryChange(for: ScrollDistances.self) { geometry in
            ScrollDistances(
                top: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                bottom: max(
                    0,
                    geometry.contentSize.height + geometry.contentInsets.bottom
                        - geometry.containerSize.height - geometry.contentOffset.y)
            )
        } action: { _, newValue in
            distances = newValue
        }
        .mask {
            PopupScrollMask(
                topDistance: distances.top,
                bottomDistance: distances.bottom,
                actionsRect: style.floatsFooter && hasActions ? actionsRect : .zero
            )
        }
        .overlay {
            if style.floatsFooter && hasActions {
                PopupFloatingActionLayout(
                    contentInset: style.padding,
                    alignment: style.actionAlignment,
                    margins: EdgeInsets(
                        top: style.buttonMarginTop, leading: style.buttonMarginLeading,
                        bottom: style.buttonMarginBottom, trailing: style.buttonMarginTrailing)
                ) {
                    actions
                        .fixedSize(horizontal: true, vertical: false)
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(coordinateSpace)) }) {
                            actionsRect = $0
                        }
                }
            }
        }
        .frame(height: height)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewportHeight = $0 }
        .coordinateSpace(name: coordinateSpace)
    }

    private var scrollRoom: CGFloat {
        guard style.floatsFooter && hasActions else { return 2 }
        let overlap =
            actionsRect.isEmpty
            ? style.buttonHeight + style.buttonMarginBottom - style.padding
            : (height ?? viewportHeight) - actionsRect.minY
        return max(2, overlap + style.actionHaloRadius)
    }
}

/// The viewport sits inside the popup's content inset; margins use the popup edge.
/// Only the intrinsic action frame intercepts clicks, leaving the rest of the row usable.
private struct PopupFloatingActionLayout: Layout {
    let contentInset: CGFloat
    let alignment: PopupStyle.ActionAlignment
    let margins: EdgeInsets

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let action = subviews[0]
        let size = action.sizeThatFits(.unspecified)
        let leading = margins.leading - contentInset
        let trailing = max(leading, bounds.width + contentInset - margins.trailing - size.width)
        let x: CGFloat
        switch alignment {
        case .leading: x = leading
        case .center: x = (leading + trailing) / 2
        case .trailing: x = trailing
        }
        let y = max(
            margins.top - contentInset,
            bounds.height + contentInset - margins.bottom - size.height)
        action.place(
            at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
            anchor: .topLeading, proposal: .unspecified)
    }
}

private struct ScrollDistances: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
}

private struct PopupScrollMask: View {
    let topDistance: CGFloat
    let bottomDistance: CGFloat
    let actionsRect: CGRect
    @Environment(\.popupStyle) private var style

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.white
                if !actionsRect.isEmpty {
                    Capsule()
                        .fill(Color.black.opacity(1 - style.actionHaloMinOpacity))
                        .frame(
                            width: actionsRect.width + style.actionHaloRadius * 2,
                            height: actionsRect.height + style.actionHaloRadius * 2
                        )
                        .blur(radius: style.actionHaloRadius / 2)
                        .position(x: actionsRect.midX, y: actionsRect.midY)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            .mask {
                edgeMask(height: geometry.size.height)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private func edgeMask(height: CGFloat) -> some View {
        if style.edgeFadeLength > 0 {
            let fraction = min(style.edgeFadeLength, height / 2) / max(height, 1)
            let topStrength = min(1, topDistance / style.edgeFadeLength)
            let bottomStrength = min(1, bottomDistance / style.edgeFadeLength)
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(1 - topStrength), location: 0),
                    .init(color: .white, location: fraction),
                    .init(color: .white, location: 1 - fraction),
                    .init(color: .white.opacity(1 - bottomStrength), location: 1),
                ], startPoint: .top, endPoint: .bottom)
        } else {
            Color.white
        }
    }
}
