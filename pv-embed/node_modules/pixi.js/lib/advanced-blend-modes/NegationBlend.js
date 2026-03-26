'use strict';

var Extensions = require('../extensions/Extensions.js');
var BlendModeFilter = require('../filters/blend-modes/BlendModeFilter.js');

"use strict";
class NegationBlend extends BlendModeFilter.BlendModeFilter {
  constructor() {
    super({
      gl: {
        functions: `
                vec3 negation(vec3 base, vec3 blend)
                {
                    return 1.0-abs(1.0-base-blend);
                }

                vec3 blendNegation(vec3 base, vec3 blend, float opacity)
                {
                    return (negation(base, blend) * opacity + base * (1.0 - opacity));
                }
                `,
        main: `
                finalColor = vec4(blendNegation(back.rgb, front.rgb, front.a), blendedAlpha) * uBlend;
                `
      },
      gpu: {
        functions: `
                fn blendNegation(base: vec3<f32>, blend: vec3<f32>) -> vec3<f32>
                {
                    return 1.0-abs(1.0-base-blend);
                }

                fn blendNegationOpacity(base: vec3<f32>, blend: vec3<f32>, opacity: f32) -> vec3<f32>
                {
                    return (blendNegation(base, blend) * opacity + base * (1.0 - opacity));
                }
            `,
        main: `
                out = vec4<f32>(blendNegationOpacity(back.rgb, front.rgb, front.a), blendedAlpha) * blendUniforms.uBlend;
            `
      }
    });
  }
}
/** @ignore */
NegationBlend.extension = {
  name: "negation",
  type: Extensions.ExtensionType.BlendMode
};

exports.NegationBlend = NegationBlend;
//# sourceMappingURL=NegationBlend.js.map
