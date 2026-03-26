var fragment = "in vec2 vTextureCoord;\nout vec4 finalColor;\nuniform sampler2D uTexture;\nvoid main() {\n    finalColor = texture(uTexture, vTextureCoord);\n}\n";

export { fragment as default };
//# sourceMappingURL=passthrough.frag.mjs.map
