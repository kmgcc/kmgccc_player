'use strict';

var Extensions = require('../extensions/Extensions.js');
var BlendModeFilter = require('../filters/blend-modes/BlendModeFilter.js');

"use strict";
class DifferenceBlend extends BlendModeFilter.BlendModeFilter {
  constructor() {
    super({
      gl: {
        functions: `
                vec3 blendDifference(vec3 base, vec3 blend,  float opacity)
                {
                    return (abs(blend - base) * opacity + base * (1.0 - opacity));
                }
            `,
        main: `
                finalColor = vec4(blendDifference(back.rgb, front.rgb,front.a), blendedAlpha) * uBlend;
            `
      },
      gpu: {
        functions: `
                fn blendDifference(base:vec3<f32>,  blend:vec3<f32>,  opacity:f32) -> vec3<f32>
                {
                    return (abs(blend - base) * opacity + base * (1.0 - opacity));
                }
            `,
        main: `
                out = vec4<f32>(blendDifference(back.rgb, front.rgb, front.a), blendedAlpha) * blendUniforms.uBlend;
            `
      }
    });
  }
}
/** @ignore */
DifferenceBlend.extension = {
  name: "difference",
  type: Extensions.ExtensionType.BlendMode
};

exports.DifferenceBlend = DifferenceBlend;
//# sourceMappingURL=DifferenceBlend.js.map
