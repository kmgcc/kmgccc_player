import SwiftUI

/// Interpolate the space occupied by the side capsules in the layout itself.
/// Every frame proposes that same intermediate width to the glass and content;
/// independently animating frames and positions can expose the target layout
/// before its capsule has reached it.
struct MiniPlayerCapsuleRowLayout: Layout {
    var leadingWidth: CGFloat
    var volumeWidth: CGFloat
    let spacing: CGFloat
    let height: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(leadingWidth, volumeWidth) }
        set {
            leadingWidth = newValue.first
            volumeWidth = newValue.second
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? leadingWidth + volumeWidth + spacing * 2, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = Self.frames(
            in: bounds, leadingWidth: leadingWidth, volumeWidth: volumeWidth, spacing: spacing
        )
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: frame.origin, anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    static func frames(in bounds: CGRect, leadingWidth: CGFloat, volumeWidth: CGFloat, spacing: CGFloat) -> [CGRect] {
        let leading = max(0, leadingWidth)
        let volume = max(0, volumeWidth)
        let center = max(0, bounds.width - leading - volume - spacing * 2)
        return [
            CGRect(x: bounds.minX, y: bounds.minY, width: leading, height: bounds.height),
            CGRect(x: bounds.minX + leading + spacing, y: bounds.minY, width: center, height: bounds.height),
            CGRect(x: bounds.maxX - volume, y: bounds.minY, width: volume, height: bounds.height)
        ]
    }
}

/// Keep artwork and transport controls fixed; give the progress area precisely
/// the remaining space, including the small undershoot of an elastic settle.
struct MiniPlayerContentLayout: Layout {
    let metrics: FullscreenMiniPlayerLayoutMetrics
    var playbackModeWidth: CGFloat
    let height: CGFloat

    var animatableData: CGFloat {
        get { playbackModeWidth }
        set { playbackModeWidth = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? metrics.minimumExpandedContainerWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let progressWidth = metrics.availableProgressAreaWidth(
            containerWidth: bounds.width + metrics.horizontalPadding * 2,
            playbackModeWidth: playbackModeWidth
        )
        let widths = [metrics.trackInfoWidth, metrics.controlsWidth, max(0, playbackModeWidth), progressWidth]
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + metrics.sectionSpacing
        }
    }
}
