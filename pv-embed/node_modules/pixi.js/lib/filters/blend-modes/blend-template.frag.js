'use strict';

Object.defineProperty(exports, '__esModule', { value: true });

var blendTemplateFrag = "\nin vec2 vTextureCoord;\nin vec4 vColor;\n\nout vec4 finalColor;\n\nuniform float uBlend;\n\nuniform sampler2D uTexture;\nuniform sampler2D uBackTexture;\n\n{FUNCTIONS}\n\nvoid main()\n{ \n    vec4 back = texture(uBackTexture, vTextureCoord);\n    vec4 front = texture(uTexture, vTextureCoord);\n    float blendedAlpha = front.a + back.a * (1.0 - front.a);\n    \n    {MAIN}\n}\n";

exports.default = blendTemplateFrag;
//# sourceMappingURL=blend-template.frag.js.map
