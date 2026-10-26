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
    /// A hidden side capsule gives up its width and its gap; its subview stays as a placeholder.
    var showsLeading = true
    var showsVolume = true

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
            in: bounds, leadingWidth: leadingWidth, volumeWidth: volumeWidth, spacing: spacing,
            showsLeading: showsLeading, showsVolume: showsVolume
        )
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: frame.origin, anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    static func frames(in bounds: CGRect, leadingWidth: CGFloat, volumeWidth: CGFloat, spacing: CGFloat,
                       showsLeading: Bool = true, showsVolume: Bool = true) -> [CGRect] {
        let leading = showsLeading ? max(0, leadingWidth) : 0
        let volume = showsVolume ? max(0, volumeWidth) : 0
        let leadingGap = showsLeading ? spacing : 0
        let volumeGap = showsVolume ? spacing : 0
        let center = max(0, bounds.width - leading - volume - leadingGap - volumeGap)
        return [
            CGRect(x: bounds.minX, y: bounds.minY, width: leading, height: bounds.height),
            CGRect(x: bounds.minX + leading + leadingGap, y: bounds.minY, width: center, height: bounds.height),
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
    /// Subviews arrive only for these sections, in reading order.
    var sections: FullscreenMiniPlayerSections = .all

    var animatableData: CGFloat {
        get { playbackModeWidth }
        set { playbackModeWidth = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? metrics.minimumExpandedContainerWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let visible = FullscreenMiniPlayerSections.order.filter { sections.contains($0) }
        let fixed = visible.reduce(0) { $0 + metrics.fixedWidth(of: $1, playbackModeWidth: playbackModeWidth) }
        let progressWidth = max(0, bounds.width - fixed - metrics.sectionSpacing * CGFloat(max(0, visible.count - 1)))
        let widths = visible.map { $0 == .progress ? progressWidth : metrics.fixedWidth(of: $0, playbackModeWidth: playbackModeWidth) }
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
