'use strict';

Object.defineProperty(exports, '__esModule', { value: true });

var fragment = "\nin vec2 vTextureCoord;\n\nout vec4 finalColor;\n\nuniform float uAlpha;\nuniform sampler2D uTexture;\n\nvoid main()\n{\n    finalColor =  texture(uTexture, vTextureCoord) * uAlpha;\n}\n";

exports.default = fragment;
//# sourceMappingURL=alpha.frag.js.map
