import SwiftUI

/// `comet` — a comet that flies in, circles a target and leaves, drawn around the node's centre.
///
/// `orbit` `[rx, ry]` is the ellipse it circles (points). `progress` (0…1) is how far along the
/// flight it is; the skin drives it from the clock. It arrives from `angle` (degrees, the side it
/// comes from, 0 = right, 90 = below), turns `sweep` degrees around the target (negative turns
/// the other way) and drifts out again. `trail` is the tail length as a share of the flight, so a
/// faster flight draws a longer streak, the way a moving light blurs. `size` is the head radius
/// in points and `width` caps the tail's half-width (at most `size`); `seed` varies the wobble.
///
/// The tail is the path the head has just travelled, so it always lies behind the head.
struct SkinSceneComet: View {
    let values: [String: SkinValue]

    var body: some View {
        Canvas { context, size in
            let orbit = values["orbit"]?.listValue.map { $0.number() } ?? []
            let rx = max(1, orbit.first ?? 120), ry = max(1, orbit.count > 1 ? orbit[1] : rx * 0.62)
            let progress = values["progress"]?.number() ?? 0
            guard progress > 0, progress < 1 else { return }
            let start = (values["angle"]?.number() ?? 180) * .pi / 180
            let sweep = (values["sweep"]?.number() ?? 300) * .pi / 180
            let trail = min(0.6, max(0.01, values["trail"]?.number() ?? 0.12))
            let head = max(0.5, values["size"]?.number() ?? 3)
            let width = max(head, values["width"]?.number() ?? head)
            let seed = values["seed"]?.number() ?? 0
            let color = values["color"]?.colorValue?.swiftUIColor ?? .white
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)

            func point(_ s: Double) -> CGPoint {
                let s = min(1, max(0, s))
                let arrive = 1 - SkinCometPath.smooth(s / 0.34)
                let leave = SkinCometPath.smooth((s - 0.7) / 0.3)
                let wobble = 0.07 * sin(2 * .pi * (s * 1.4) + seed * 5.1)
                let rho = 1 + 1.7 * arrive * arrive + 1.3 * leave * leave + wobble
                let theta = start + sweep * s
                return CGPoint(x: centre.x + rx * rho * cos(theta), y: centre.y + ry * rho * sin(theta))
            }

            let alpha = SkinCometPath.smooth(progress / 0.1) * (1 - SkinCometPath.smooth((progress - 0.82) / 0.18))
            guard alpha > 0.001 else { return }
            let tail = max(0, progress - trail)
            let samples = 40
            let points = (0...samples).map { point(tail + (progress - tail) * Double($0) / Double(samples)) }
            SkinCometPath.draw(in: &context, points: points, width: width, head: head, color: color, alpha: alpha)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Shared comet drawing for the `comet` node and particle comets.
enum SkinCometPath {
    nonisolated static func smooth(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// `points` run from the tail to the head. The tail is one filled outline, so no seams or
    /// beads appear along it: it widens from nothing to `width` and fades in from transparent,
    /// and a solid disc of radius `head` sits on its front end.
    nonisolated static func draw(in context: inout GraphicsContext, points: [CGPoint], width: Double, head: Double, color: Color, alpha: Double) {
        guard let front = points.last else { return }
        var lengths = [0.0]
        for index in points.indices.dropFirst() {
            lengths.append(lengths[index - 1] + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y))
        }
        let total = lengths.last ?? 0
        if total > 1, points.count > 2 {
            var left: [CGPoint] = [], right: [CGPoint] = []
            for index in points.indices {
                let a = points[max(0, index - 1)], b = points[min(points.count - 1, index + 1)]
                let dx = b.x - a.x, dy = b.y - a.y
                let length = max(0.0001, hypot(dx, dy))
                let u = lengths[index] / total
                let half = min(width, head) * pow(u, 1.6)
                left.append(CGPoint(x: points[index].x - dy / length * half, y: points[index].y + dx / length * half))
                right.append(CGPoint(x: points[index].x + dy / length * half, y: points[index].y - dx / length * half))
            }
            // The front end is as wide as the head, which covers it.
            var ribbon = Path()
            ribbon.move(to: points[0])
            left.dropFirst().forEach { ribbon.addLine(to: $0) }
            right.reversed().dropLast().forEach { ribbon.addLine(to: $0) }
            ribbon.closeSubpath()
            // The gradient runs along the chord from tail to head; each stop sits where that
            // share of the tail's length projects onto the chord, so a curved tail fades evenly.
            let chord = CGPoint(x: front.x - points[0].x, y: front.y - points[0].y)
            let chordLength = max(0.0001, chord.x * chord.x + chord.y * chord.y)
            var stops: [Gradient.Stop] = []
            var last = -1.0
            for fraction in [0.0, 0.2, 0.4, 0.6, 0.75, 0.88, 1.0] {
                let index = lengths.firstIndex { $0 >= fraction * total } ?? points.count - 1
                let p = points[index]
                let projected = Double(((p.x - points[0].x) * chord.x + (p.y - points[0].y) * chord.y) / chordLength)
                let location = min(1, max(last + 0.001, projected))
                last = location
                stops.append(.init(color: color.opacity(alpha * pow(fraction, 2.2)), location: min(1, location)))
            }
            context.fill(ribbon, with: .linearGradient(Gradient(stops: stops), startPoint: points[0], endPoint: front))
        }
        context.fill(Path(ellipseIn: CGRect(x: front.x - head, y: front.y - head, width: head * 2, height: head * 2)), with: .color(color.opacity(alpha)))
    }
}
