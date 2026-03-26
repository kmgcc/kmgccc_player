'use strict';

Object.defineProperty(exports, '__esModule', { value: true });

var fragment = "in vec2 vTextureCoord;\nout vec4 finalColor;\nuniform sampler2D uTexture;\nvoid main() {\n    finalColor = texture(uTexture, vTextureCoord);\n}\n";

exports.default = fragment;
//# sourceMappingURL=passthrough.frag.js.map
