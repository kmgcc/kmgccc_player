import SwiftUI

/// `fov` — a lens edge for a whole subtree, strongest in the corners and absent inside `start`.
///
/// `distortion` (−0.6…0.6) stretches the edges outward like a wide-angle lens; `chromatic`
/// (points) splits red and blue along the radius; `blur` (points) is the Gaussian radius at the
/// corners, growing from zero at `start` (0…1 of the half-diagonal). The lens is one pass of three
/// samples; the blur is a separable pair, so a pixel inside `start` costs one sample per pass.
enum SkinSceneFOV {
    static func apply(_ view: AnyView, filter: SkinValue, enabled: Bool) -> AnyView {
        guard enabled else { return view }
        let distortion = min(0.6, max(-0.6, filter[member: "distortion"].number(0.2)))
        let chromatic = max(0, min(8, filter[member: "chromatic"].number(1.5)))
        let blur = max(0, min(32, filter[member: "blur"].number(6)))
        let start = filter[member: "start"].number(0.45).clamped01
        let reach = ceil(max(blur, chromatic)) + 1
        let library = ShaderLibrary.default
        var view = view
        if abs(distortion) > 0.001 || chromatic > 0.05 {
            view = SkinSceneFilters.padded(view, reach: reach) { padded in
                padded.visualEffect { effect, proxy in
                    // The stretch samples up to `0.35 * |distortion|` of the half size away from
                    // the pixel (at the corners). The offset must cover it, or a partial redraw
                    // reads nothing there and text near the left and right edges is cut off.
                    let stretch = 0.35 * abs(distortion) * 1.05
                    return effect.layerEffect(
                        library.skinFxLens(.float2(proxy.size), .float(reach), .float(distortion), .float(chromatic), .float(start)),
                        maxSampleOffset: CGSize(width: ceil(proxy.size.width / 2 * stretch) + reach, height: ceil(proxy.size.height / 2 * stretch) + reach))
                }
            }
        }
        if blur > 0.4 {
            for axis in [CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)] {
                view = SkinSceneFilters.padded(view, reach: reach) { padded in
                    padded.visualEffect { effect, proxy in
                        effect.layerEffect(
                            library.skinFxEdgeBlur(.float2(proxy.size), .float(reach), .float2(axis.x, axis.y), .float(blur), .float(start)),
                            maxSampleOffset: CGSize(width: reach * axis.x, height: reach * axis.y))
                    }
                }
            }
        }
        return view
    }
}
