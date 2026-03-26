'use strict';

var Extensions = require('../extensions/Extensions.js');
var BlendModeFilter = require('../filters/blend-modes/BlendModeFilter.js');

"use strict";
class LinearBurnBlend extends BlendModeFilter.BlendModeFilter {
  constructor() {
    super({
      gl: {
        functions: `
                float linearBurn(float base, float blend)
                {
                    return max(0.0, base + blend - 1.0);
                }

                vec3 blendLinearBurn(vec3 base, vec3 blend, float opacity)
                {
                    vec3 blended = vec3(
                        linearBurn(base.r, blend.r),
                        linearBurn(base.g, blend.g),
                        linearBurn(base.b, blend.b)
                    );

                    return (blended * opacity + base * (1.0 - opacity));
                }
                `,
        main: `
                finalColor = vec4(blendLinearBurn(back.rgb, front.rgb,front.a), blendedAlpha) * uBlend;
                `
      },
      gpu: {
        functions: `
                fn linearBurn(base: f32, blend: f32) -> f32
                {
                    return max(0.0, base + blend - 1.0);
                }

                fn blendLinearBurn(base:vec3<f32>,  blend:vec3<f32>,  opacity:f32) -> vec3<f32>
                {
                    let blended = vec3<f32>(
                        linearBurn(base.r, blend.r),
                        linearBurn(base.g, blend.g),
                        linearBurn(base.b, blend.b)
                    );

                    return (blended * opacity + base * (1.0 - opacity));
                }
                `,
        main: `
                out = vec4<f32>(blendLinearBurn(back.rgb, front.rgb, front.a), blendedAlpha) * blendUniforms.uBlend;
                `
      }
    });
  }
}
/** @ignore */
LinearBurnBlend.extension = {
  name: "linear-burn",
  type: Extensions.ExtensionType.BlendMode
};

exports.LinearBurnBlend = LinearBurnBlend;
//# sourceMappingURL=LinearBurnBlend.js.map
