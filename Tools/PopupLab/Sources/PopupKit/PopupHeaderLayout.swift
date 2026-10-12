import AppKit
import CoreText
import SwiftUI

/// Aligns side controls with the visible glyphs on the first title line.
/// The title's baseline remains the anchor when its block wraps or has a subtitle.
struct PopupHeaderLayout: Layout {
    let title: String
    let titleSize: Double
    let spacing: Double
    let hasIcon: Bool
    let hasClose: Bool
    let contentInset: Double
    let closeTop: Double
    let closeTrailing: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measure(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measurement = measure(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for index in subviews.indices {
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + measurement.origins[index].x,
                    y: bounds.minY + measurement.origins[index].y),
                anchor: .topLeading, proposal: measurement.proposals[index]
            )
        }
    }

    private func measure(proposal: ProposedViewSize, subviews: Subviews) -> Measurement {
        let titleIndex = hasIcon ? 1 : 0
        let closeIndex = titleIndex + 1
        let iconSize = hasIcon ? subviews[0].sizeThatFits(.unspecified) : .zero
        let closeSize = hasClose ? subviews[closeIndex].sizeThatFits(.unspecified) : .zero
        let sideWidth =
            contentInset * 2 + iconSize.width + closeSize.width
            + spacing * Double((hasIcon ? 1 : 0) + (hasClose ? 1 : 0))
        let width = proposal.width ?? (subviews[titleIndex].sizeThatFits(.unspecified).width + sideWidth)
        let titleX = contentInset + (hasIcon ? iconSize.width + spacing : 0)
        let closeX = width - closeTrailing - closeSize.width
        let titleRight = hasClose ? closeX - spacing : width - contentInset
        let titleWidth = max(1, titleRight - titleX)
        let titleProposal = ProposedViewSize(width: titleWidth, height: nil)
        let titleDimensions = subviews[titleIndex].dimensions(in: titleProposal)
        let titleCenter = titleDimensions[.firstTextBaseline] - firstLineInkCenter(width: titleWidth)
        let sharedCenter = contentInset + max(titleCenter, iconSize.height / 2, closeSize.height / 2)
        var origins = Array(repeating: CGPoint.zero, count: subviews.count)
        var proposals = Array(repeating: ProposedViewSize.unspecified, count: subviews.count)
        origins[titleIndex] = CGPoint(
            x: titleX,
            y: sharedCenter - titleCenter)
        proposals[titleIndex] = titleProposal
        if hasIcon {
            origins[0] = CGPoint(x: contentInset, y: sharedCenter - iconSize.height / 2)
        }
        if hasClose {
            origins[closeIndex] = CGPoint(x: closeX, y: closeTop)
        }
        let height = max(
            origins[titleIndex].y + titleDimensions.height,
            sharedCenter + iconSize.height / 2,
            hasClose ? closeTop + closeSize.height : 0)
        return Measurement(size: CGSize(width: width, height: height), origins: origins, proposals: proposals)
    }

    private func firstLineInkCenter(width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: titleSize, weight: .semibold)
        let text = NSAttributedString(string: title, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        let length = CTTypesetterSuggestLineBreak(typesetter, 0, Double(width))
        let line = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: length))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return ink.isEmpty ? font.capHeight / 2 : ink.midY
    }

    private struct Measurement {
        let size: CGSize
        let origins: [CGPoint]
        let proposals: [ProposedViewSize]
    }
}
