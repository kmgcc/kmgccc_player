// Built-in `fov` lens filter for Scene v2 skins.
//
// Two kinds of pass share one edge factor: 0 inside `edgeStart` (as a fraction of the
// half-diagonal), rising smoothly to 1 at the corners.
//
// skinFxLens      wide-angle stretch plus lateral chromatic aberration, three samples.
// skinFxEdgeBlur  one axis of a Gaussian whose radius follows the edge factor. Run once
//                 horizontally and once vertically. Taps are spaced at most ~1pt apart
//                 (up to 16 per side), so a wide radius stays a smooth blur, never copies.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float skinFxEdge(float2 position, float2 size, float inset, float edgeStart) {
    float2 half_ = max((size - 2.0 * inset) * 0.5, float2(1.0));
    float2 c = (position - size * 0.5) / half_;
    float r = length(c) * 0.70710678;
    return smoothstep(clamp(edgeStart, 0.0, 0.98), 1.0, r);
}

[[stitchable]] half4 skinFxLens(float2 position, SwiftUI::Layer layer,
                                float2 size, float inset, float distortion,
                                float chromatic, float edgeStart) {
    float2 lo = float2(inset), hi = size - float2(inset);
    float2 centre = size * 0.5;
    float2 half_ = max((size - 2.0 * inset) * 0.5, float2(1.0));
    float2 c = (position - centre) / half_;
    float r2 = dot(c, c) * 0.5;

    // Wide-angle stretch: the source moves toward the centre as r² grows, so the edges are
    // magnified outward and nothing is sampled from beyond the frame.
    float2 source = centre + (position - centre) * (1.0 - clamp(distortion, -0.6, 0.6) * 0.35 * r2);
    float edge = skinFxEdge(position, size, inset, edgeStart);
    float2 radial = length(c) > 1e-4 ? normalize(position - centre) : float2(0.0);
    float2 split = radial * max(0.0, chromatic) * edge;

    half4 g = layer.sample(clamp(source, lo, hi));
    if (chromatic <= 0.0 || edge <= 0.0) { return g; }
    half4 r = layer.sample(clamp(source + split, lo, hi));
    half4 b = layer.sample(clamp(source - split, lo, hi));
    half a = max(g.a, max(r.a, b.a));
    return half4(r.r, g.g, b.b, a);
}

[[stitchable]] half4 skinFxEdgeBlur(float2 position, SwiftUI::Layer layer,
                                    float2 size, float inset, float2 axis,
                                    float radius, float edgeStart) {
    float edge = skinFxEdge(position, size, inset, edgeStart);
    float reach = max(0.0, radius) * edge * edge;
    if (reach < 0.4) { return layer.sample(position); }

    float2 lo = float2(inset), hi = size - float2(inset);
    int taps = int(min(16.0, ceil(reach)));
    float spacing = reach / float(taps);
    float sigma = reach * 0.5;
    float falloff = 1.0 / (2.0 * sigma * sigma);

    float4 sum = float4(layer.sample(position));
    float weight = 1.0;
    for (int i = 1; i <= taps; i++) {
        float d = spacing * float(i);
        float w = exp(-d * d * falloff);
        sum += w * float4(layer.sample(clamp(position + axis * d, lo, hi)));
        sum += w * float4(layer.sample(clamp(position - axis * d, lo, hi)));
        weight += 2.0 * w;
    }
    return half4(sum / weight);
}
