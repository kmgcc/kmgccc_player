float4 skinColor(float2 uv, constant SkinUniforms& u, texture2d<float> artwork) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 drift = float2(sin(uv.y * 6.0 + u.time * 0.3), cos(uv.x * 5.0 - u.time * 0.2));
    float2 p = clamp(uv + drift * (0.025 + u.bass * 0.045), 0.0, 1.0);
    float3 cover = artwork.sample(linearSampler, p).rgb;
    float glow = 0.5 + 0.5 * sin((p.x + p.y) * 4.0 + u.time * 0.15);
    return float4(mix(cover * 0.38, u.accent.rgb * 0.55, glow * 0.35), 1.0);
}
