'use strict';

Object.defineProperty(exports, '__esModule', { value: true });

var fragment = "varying vec2 vUV;\nvarying vec4 vColor;\n\nuniform sampler2D uTexture;\n\nvoid main(void){\n    vec4 color = texture2D(uTexture, vUV) * vColor;\n    gl_FragColor = color;\n}";

exports.default = fragment;
//# sourceMappingURL=particles.frag.js.map
