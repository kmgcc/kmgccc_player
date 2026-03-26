'use strict';

var Extensions = require('../extensions/Extensions.js');
var BlendModeFilter = require('../filters/blend-modes/BlendModeFilter.js');

"use strict";
class LinearDodgeBlend extends BlendModeFilter.BlendModeFilter {
  constructor() {
    super({
      gl: {
        functions: `
                float linearDodge(float base, float blend) {
                    return min(1.0, base + blend);
                }

                vec3 blendLinearDodge(vec3 base, vec3 blend, float opacity) {
                    vec3 blended = vec3(
                        linearDodge(base.r, blend.r),
                        linearDodge(base.g, blend.g),
                        linearDodge(base.b, blend.b)
                    );
                    return (blended * opacity + base * (1.0 - opacity));
                }
                `,
        main: `
                finalColor = vec4(blendLinearDodge(back.rgb, front.rgb,front.a), blendedAlpha) * uBlend;
                `
      },
      gpu: {
        functions: `
                fn linearDodge(base: f32, blend: f32) -> f32
                {
                    return min(1, base + blend);
                }

                fn blendLinearDodge(base:vec3<f32>, blend:vec3<f32>,  opacity:f32) -> vec3<f32>
                {
                    let blended = vec3<f32>(
                        linearDodge(base.r, blend.r),
                        linearDodge(base.g, blend.g),
                        linearDodge(base.b, blend.b)
                    );

                    return (blended * opacity + base * (1.0 - opacity));
                }
            `,
        main: `
                out = vec4<f32>(blendLinearDodge(back.rgb, front.rgb, front.a), blendedAlpha) * blendUniforms.uBlend;
            `
      }
    });
  }
}
/** @ignore */
LinearDodgeBlend.extension = {
  name: "linear-dodge",
  type: Extensions.ExtensionType.BlendMode
};

exports.LinearDodgeBlend = LinearDodgeBlend;
//# sourceMappingURL=LinearDodgeBlend.js.map
