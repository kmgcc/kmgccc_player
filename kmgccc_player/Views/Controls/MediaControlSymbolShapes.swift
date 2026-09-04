//
//  MediaControlSymbolShapes.swift
//  myPlayer2
//
//  kmgccc_player - Rebuilt play / pause / skip symbols as native SwiftUI shapes.
//  The outlines are faithful conversions of the vector paths frozen in
//  Tools/Demos/amll-controls-demo.html (Apple-Music style control demo):
//    Play / Pause     -> viewBox 0 0 38 38
//    Skip arrow       -> viewBox 0 0 134 134
//  All coordinate transforms happen in `path(in:)` so the shapes scale
//  cleanly at any metrics without raster blur.
//

import SwiftUI

// MARK: - SVG conversion helper

private enum SvgPathMap {
    /// Maps one SVG viewBox coordinate into a target rect, centered and
    /// aspect-uniform. `mirror` flips the x axis (used by the previous-track
    /// arrow so both skip shapes share a single outline).
    /// `nonisolated` because `Shape.path(in:)` runs in a nonisolated context.
    nonisolated static func point(
        _ x: CGFloat,
        _ y: CGFloat,
        in rect: CGRect,
        viewBox: CGFloat,
        mirror: Bool = false
    ) -> CGPoint {
        let scale = min(rect.width, rect.height) / viewBox
        let screenX = mirror ? (viewBox - x) : x
        let dx = rect.midX - (viewBox / 2) * scale
        let dy = rect.midY - (viewBox / 2) * scale
        return CGPoint(x: dx + screenX * scale, y: dy + y * scale)
    }
}

// MARK: - Play triangle

/// Solid play triangle, matching the demo's rounded-leading-edge outline.
struct MediaControlPlaySymbol: Shape {
    func path(in rect: CGRect) -> Path {
        let vb: CGFloat = 38
        var path = Path()
        path.move(to: SvgPathMap.point(5.80762, 32.4896, in: rect, viewBox: vb))
        path.addLine(to: SvgPathMap.point(5.80762, 5.4925, in: rect, viewBox: vb))
        path.addCurve(
            to: SvgPathMap.point(6.75391, 2.82063, in: rect, viewBox: vb),
            control1: SvgPathMap.point(5.80762, 4.305, in: rect, viewBox: vb),
            control2: SvgPathMap.point(6.12305, 3.41438, in: rect, viewBox: vb)
        )
        path.addCurve(
            to: SvgPathMap.point(9.01758, 1.93, in: rect, viewBox: vb),
            control1: SvgPathMap.point(7.38477, 2.22688, in: rect, viewBox: vb),
            control2: SvgPathMap.point(8.13932, 1.93, in: rect, viewBox: vb)
        )
        path.addCurve(
            to: SvgPathMap.point(11.2812, 2.56086, in: rect, viewBox: vb),
            control1: SvgPathMap.point(9.78451, 1.93, in: rect, viewBox: vb),
            control2: SvgPathMap.point(10.5391, 2.14029, in: rect, viewBox: vb)
        )
        path.addLine(to: SvgPathMap.point(33.7324, 15.6605, in: rect, viewBox: vb))
        path.addCurve(
            to: SvgPathMap.point(35.6436, 17.1634, in: rect, viewBox: vb),
            control1: SvgPathMap.point(34.5859, 16.1553, in: rect, viewBox: vb),
            control2: SvgPathMap.point(35.223, 16.6562, in: rect, viewBox: vb)
        )
        path.addCurve(
            to: SvgPathMap.point(36.2744, 19.0003, in: rect, viewBox: vb),
            control1: SvgPathMap.point(36.0641, 17.6582, in: rect, viewBox: vb),
            control2: SvgPathMap.point(36.2744, 18.2705, in: rect, viewBox: vb)
        )
        path.addCurve(
            to: SvgPathMap.point(35.6436, 20.8372, in: rect, viewBox: vb),
            control1: SvgPathMap.point(36.2744, 19.7054, in: rect, viewBox: vb),
            control2: SvgPathMap.point(36.0641, 20.3177, in: rect, viewBox: vb)
        )
        path.addCurve(
            to: SvgPathMap.point(33.7324, 22.3216, in: rect, viewBox: vb),
            control1: SvgPathMap.point(35.223, 21.3444, in: rect, viewBox: vb),
            control2: SvgPathMap.point(34.5859, 21.8392, in: rect, viewBox: vb)
        )
        path.addLine(to: SvgPathMap.point(11.2812, 35.4212, in: rect, viewBox: vb))
        path.addCurve(
            to: SvgPathMap.point(9.01758, 36.0706, in: rect, viewBox: vb),
            control1: SvgPathMap.point(10.5391, 35.8542, in: rect, viewBox: vb),
            control2: SvgPathMap.point(9.78451, 36.0706, in: rect, viewBox: vb)
        )
        path.addCurve(
            to: SvgPathMap.point(6.75391, 35.1614, in: rect, viewBox: vb),
            control1: SvgPathMap.point(8.13932, 36.0706, in: rect, viewBox: vb),
            control2: SvgPathMap.point(7.38477, 35.7676, in: rect, viewBox: vb)
        )
        path.addCurve(
            to: SvgPathMap.point(5.80762, 32.4896, in: rect, viewBox: vb),
            control1: SvgPathMap.point(6.12305, 34.5677, in: rect, viewBox: vb),
            control2: SvgPathMap.point(5.80762, 33.6771, in: rect, viewBox: vb)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Pause bars

/// Solid pause bars (two rounded vertical capsules), demo outline.
struct MediaControlPauseSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        let vb: CGFloat = 38
        var path = Path()

        // Left bar.
        path.move(to: SvgPathMap.point(8.46953, 37, in: rect, viewBox: vb))
        path.addCurve(
            to: SvgPathMap.point(6.03359, 36.1814, in: rect, viewBox: vb),
            control1: SvgPathMap.point(7.37801, 37, in: rect, viewBox: vb),
            control2: SvgPathMap.point(6.56603, 36.7271, in: rect, viewBox: vb)
        )
        path.addCurve(
            to: SvgPathMap.point(5.25488, 33.7854, in: rect, viewBox: vb),
            control1: SvgPathMap.point(5.51445, 35.6489, in: rect, viewBox: vb),
            control2: SvgPathMap.point(5.25488, 34.8502, in: rect, viewBox: vb)
        )
        path.addLine(to: SvgPathMap.point(5.25488, 4.21464, in: rect, viewBox: vb))
        path.addCurve(
            to: SvgPathMap.point(6.05355, 1.81864, in: rect, viewBox: vb),
            control1: SvgPathMap.point(5.25488, 3.14975, in: rect, viewBox: vb),
            control2: SvgPathMap.point(5.52111, 2.35108, in: rect, viewBox: vb)
        )
        path.addCurve(
            to: SvgPathMap.point(8.46953, 1, in: rect, viewBox: vb),
            control1: SvgPathMap.point(6.59931, 1.27288, in: rect, viewBox: vb),
            control2: SvgPathMap.point(7.40463, 1, in: rect, viewBox: vb)
        )
        path.addLine(to: SvgPathMap.point(13.3813, 1, in: rect, viewBox: vb))
        path.addCurve(
            to: SvgPathMap.point(15.7574, 1.81864, in: rect, viewBox: vb),
            control1: SvgPathMap.point(14.4329, 1, in: rect, viewBox: vb),
            control2: SvgPathMap.point(15.2249, 1.27288, in: rect, viewBox: vb)
        )
        path.addCurve(
            to: SvgPathMap.point(16.576, 4.21464, in: rect, viewBox: vb),
            control1: SvgPathMap.point(16.3031, 2.35108, in: rect, viewBox: vb),
            control2: SvgPathMap.point(16.576, 3.14975, in: rect, viewBox: vb)
        )
        path.addLine(to: SvgPathMap.point(16.576, 33.7854, in: rect, viewBox: vb))
        path.addCurve(
            to: SvgPathMap.point(15.7574, 36.1814, in: rect, viewBox: vb),
            control1: SvgPathMap.point(16.576, 34.8502, in: rect, viewBox: vb),
            control2: SvgPathMap.point(16.3031, 35.6489, in: rect, viewBox: vb)
        )
        path.addCurve(
            to: SvgPathMap.point(13.3813, 37, in: rect, viewBox: vb),
            control1: SvgPathMap.point(15.2249, 36.7271, in: rect, viewBox: vb),
            control2: SvgPathMap.point(14.4329, 37, in: rect, viewBox: vb)
        )
        path.addLine(to: SvgPathMap.point(8.46953, 37, in: rect, viewBox: vb))
        path.closeSubpath()

        // Right bar.
        path.move(to: SvgPathMap.point(24.6426, 37, in: rect, viewBox: vb))
        path.addCurve(
            to: SvgPathMap.point(22.2266, 36.1814, in: rect, viewBox: vb),
            control1: SvgPathMap.point(23.5644, 37, in: rect, viewBox: vb),
            control2: SvgPathMap.point(22.759, 36.7271, in: rect, viewBox: vb)
        )
        path.addCurve(
            to: SvgPathMap.point(21.4279, 33.7854, in: rect, viewBox: vb),
            control1: SvgPathMap.point(21.6942, 35.6489, in: rect, viewBox: vb),
            control2: SvgPathMap.point(21.4279, 34.8502, in: rect, viewBox: vb)
        )
        path.addLine(to: SvgPathMap.point(21.4279, 4.21464, in: rect, viewBox: vb))
        path.addCurve(
            to: SvgPathMap.point(22.2266, 1.81864, in: rect, viewBox: vb),
            control1: SvgPathMap.point(21.4279, 3.14975, in: rect, viewBox: vb),
            control2: SvgPathMap.point(21.6942, 2.35108, in: rect, viewBox: vb)
        )
        path.addCurve(
            to: SvgPathMap.point(24.6426, 1, in: rect, viewBox: vb),
            control1: SvgPathMap.point(22.7724, 1.27288, in: rect, viewBox: vb),
            control2: SvgPathMap.point(23.5777, 1, in: rect, viewBox: vb)
        )
        path.addLine(to: SvgPathMap.point(29.5544, 1, in: rect, viewBox: vb))
        path.addCurve(
            to: SvgPathMap.point(31.9504, 1.81864, in: rect, viewBox: vb),
            control1: SvgPathMap.point(30.6193, 1, in: rect, viewBox: vb),
            control2: SvgPathMap.point(31.4179, 1.27288, in: rect, viewBox: vb)
        )
        path.addCurve(
            to: SvgPathMap.point(32.7491, 4.21464, in: rect, viewBox: vb),
            control1: SvgPathMap.point(32.4828, 2.35108, in: rect, viewBox: vb),
            control2: SvgPathMap.point(32.7491, 3.14975, in: rect, viewBox: vb)
        )
        path.addLine(to: SvgPathMap.point(32.7491, 33.7854, in: rect, viewBox: vb))
        path.addCurve(
            to: SvgPathMap.point(31.9504, 36.1814, in: rect, viewBox: vb),
            control1: SvgPathMap.point(32.7491, 34.8502, in: rect, viewBox: vb),
            control2: SvgPathMap.point(32.4828, 35.6489, in: rect, viewBox: vb)
        )
        path.addCurve(
            to: SvgPathMap.point(29.5544, 37, in: rect, viewBox: vb),
            control1: SvgPathMap.point(31.4179, 36.7271, in: rect, viewBox: vb),
            control2: SvgPathMap.point(30.6193, 37, in: rect, viewBox: vb)
        )
        path.addLine(to: SvgPathMap.point(24.6426, 37, in: rect, viewBox: vb))
        path.closeSubpath()
        return path
    }
}

// MARK: - Skip arrow

/// Single solid forward arrow (head pointing +x). `mirrored` flips the
/// outline along the vertical axis so the previous-track button reuses the
/// exact same geometry. In the demo this is the left arrow of the next
/// button / right arrow of the previous button, drawn in a 134x134 viewBox
/// where the two visible arrows sit 40 units apart.
///
/// The mapping centers the arrow's own bounding box (x 29...68.57, center
/// 48.785 — its mirrored counterpart 85.215) on the stage center, NOT the
/// viewBox center: the raw outline is off-center inside the 134 box, and a
/// viewBox-centered mapping made the previous button's pair visibly lopsided.
struct MediaControlSkipArrowSymbol: Shape {
    var mirrored: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(62, 60.0717, rect))
        path.addCurve(to: pt(68.5677, 64.9662, rect), control1: pt(65.938, 62.3453, rect), control2: pt(67.9069, 63.4821, rect))
        path.addCurve(to: pt(68.5677, 69.0336, rect), control1: pt(69.1441, 66.2608, rect), control2: pt(69.1441, 67.7391, rect))
        path.addCurve(to: pt(62, 73.9281, rect), control1: pt(67.9069, 70.5177, rect), control2: pt(65.938, 71.6545, rect))
        path.addLine(to: pt(41, 86.0525, rect))
        path.addCurve(to: pt(33.4774, 89.293, rect), control1: pt(37.062, 88.326, rect), control2: pt(35.0931, 89.4628, rect))
        path.addCurve(to: pt(29.9549, 87.2593, rect), control1: pt(32.0681, 89.1449, rect), control2: pt(30.7878, 88.4057, rect))
        path.addCurve(to: pt(29, 79.1243, rect), control1: pt(29, 85.945, rect), control2: pt(29, 83.6714, rect))
        path.addLine(to: pt(29, 54.8755, rect))
        path.addCurve(to: pt(29.9549, 46.7405, rect), control1: pt(29, 50.3284, rect), control2: pt(29, 48.0548, rect))
        path.addCurve(to: pt(33.4774, 44.7068, rect), control1: pt(30.7878, 45.5941, rect), control2: pt(32.0681, 44.8549, rect))
        path.addCurve(to: pt(41, 47.9473, rect), control1: pt(35.0931, 44.537, rect), control2: pt(37.062, 45.6738, rect))
        path.addLine(to: pt(62, 60.0717, rect))
        path.closeSubpath()
        return path
    }

    private func pt(_ x: CGFloat, _ y: CGFloat, _ rect: CGRect) -> CGPoint {
        let scale = min(rect.width, rect.height) / 134
        // Arrow bbox center in the 134 viewBox (x 29...68.5677), and its
        // mirrored counterpart. y is symmetric around the viewBox middle.
        let bboxCenterX: CGFloat = mirrored ? 134 - 48.785 : 48.785
        let screenX = mirrored ? 134 - x : x
        return CGPoint(
            x: rect.midX + (screenX - bboxCenterX) * scale,
            y: rect.midY + (y - 67) * scale
        )
    }
}