var fragment = "\nin vec2 vTextureCoord;\nin vec2 vFilterUv;\n\nout vec4 finalColor;\n\nuniform sampler2D uTexture;\nuniform sampler2D uMapTexture;\n\nuniform vec4 uInputClamp;\nuniform highp vec4 uInputSize;\nuniform mat2 uRotation;\nuniform vec2 uScale;\n\nvoid main()\n{\n    vec4 map = texture(uMapTexture, vFilterUv);\n    \n    vec2 offset = uInputSize.zw * (uRotation * (map.xy - 0.5)) * uScale; \n\n    finalColor = texture(uTexture, clamp(vTextureCoord + offset, uInputClamp.xy, uInputClamp.zw));\n}\n";

export { fragment as default };
//# sourceMappingURL=displacement.frag.mjs.map
