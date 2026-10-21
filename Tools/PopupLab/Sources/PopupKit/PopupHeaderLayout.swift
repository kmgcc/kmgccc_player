import AppKit
import CoreText
import SwiftUI

/// Subtitle continuation lines grow down without shifting the icon's visual anchor.
struct PopupHeaderLayout: Layout {
    let title: String
    let titleSize: Double
    let subtitle: String?
    let subtitleSize: Double
    let titleBodySpacing: Double
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
        let hasSubtitle = subtitle.map { !$0.isEmpty } ?? false
        let subtitleIndex = titleIndex + 1
        let closeIndex = subtitleIndex + (hasSubtitle ? 1 : 0)
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
        let subtitleDimensions = hasSubtitle ? subviews[subtitleIndex].dimensions(in: titleProposal) : nil
        let titleFont = NSFont.systemFont(ofSize: titleSize, weight: .semibold)
        let firstInk = lineInkBounds(title, font: titleFont, width: titleWidth, lastLine: false)
        let inkBottom: CGFloat
        if let subtitle, let subtitleDimensions {
            let subtitleInk = lineInkBounds(
                subtitle, font: .systemFont(ofSize: subtitleSize), width: titleWidth, lastLine: false)
            inkBottom = titleDimensions.height + titleBodySpacing
                + subtitleDimensions[.firstTextBaseline] - subtitleInk.minY
        } else {
            let lastInk = lineInkBounds(title, font: titleFont, width: titleWidth, lastLine: true)
            inkBottom = titleDimensions[.lastTextBaseline] - lastInk.minY
        }
        let inkTop = titleDimensions[.firstTextBaseline] - firstInk.maxY
        let titleCenter = (inkTop + inkBottom) / 2
        let sharedCenter = contentInset + max(titleCenter, iconSize.height / 2, closeSize.height / 2)
        var origins = Array(repeating: CGPoint.zero, count: subviews.count)
        var proposals = Array(repeating: ProposedViewSize.unspecified, count: subviews.count)
        origins[titleIndex] = CGPoint(
            x: titleX,
            y: sharedCenter - titleCenter)
        proposals[titleIndex] = titleProposal
        if subtitleDimensions != nil {
            origins[subtitleIndex] = CGPoint(
                x: titleX, y: origins[titleIndex].y + titleDimensions.height + titleBodySpacing)
            proposals[subtitleIndex] = titleProposal
        }
        if hasIcon {
            origins[0] = CGPoint(x: contentInset, y: sharedCenter - iconSize.height / 2)
        }
        if hasClose {
            origins[closeIndex] = CGPoint(x: closeX, y: closeTop)
        }
        let textHeight = titleDimensions.height
            + (subtitleDimensions.map { titleBodySpacing + $0.height } ?? 0)
        let height = max(
            origins[titleIndex].y + textHeight,
            sharedCenter + iconSize.height / 2,
            hasClose ? closeTop + closeSize.height : 0)
        return Measurement(size: CGSize(width: width, height: height), origins: origins, proposals: proposals)
    }

    private func lineInkBounds(_ title: String, font: NSFont, width: CGFloat, lastLine: Bool) -> CGRect {
        let text = NSAttributedString(string: title, attributes: [.font: font])
        let fallback = CGRect(x: 0, y: 0, width: 1, height: font.capHeight)
        guard text.length > 0 else { return fallback }
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var range = CFRange(location: 0, length: 0)
        repeat {
            range.location += range.length
            range.length = max(1, CTTypesetterSuggestLineBreak(typesetter, range.location, Double(width)))
        } while lastLine && range.location + range.length < text.length
        let line = CTTypesetterCreateLine(typesetter, range)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return ink.isEmpty ? fallback : ink
    }

    private struct Measurement {
        let size: CGSize
        let origins: [CGPoint]
        let proposals: [ProposedViewSize]
    }
}
