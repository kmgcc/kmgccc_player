'use strict';

var Extensions = require('../extensions/Extensions.js');
var BlendModeFilter = require('../filters/blend-modes/BlendModeFilter.js');
var GLhls = require('../filters/blend-modes/hls/GLhls.js');
var GPUhls = require('../filters/blend-modes/hls/GPUhls.js');

"use strict";
class SaturationBlend extends BlendModeFilter.BlendModeFilter {
  constructor() {
    super({
      gl: {
        functions: `
                ${GLhls.hslgl}

                vec3 blendSaturation(vec3 base, vec3 blend,  float opacity)
                {
                    vec3 blendSaturation = setLuminosity(setSaturation(base, getSaturation(blend)), getLuminosity(base));
                    return (blendSaturation * opacity + base * (1.0 - opacity));
                }
            `,
        main: `
                finalColor = vec4(blendSaturation(back.rgb, front.rgb, front.a), blendedAlpha) * uBlend;
            `
      },
      gpu: {
        functions: `
                ${GPUhls.hslgpu}

                fn blendSaturation(base:vec3<f32>,  blend:vec3<f32>,  opacity:f32) -> vec3<f32>
                {
                    let blendSaturation = setLuminosity(setSaturation(base, getSaturation(blend)), getLuminosity(base));
                    return (blendSaturation * opacity + base * (1.0 - opacity));
                }
            `,
        main: `
                out = vec4<f32>(blendSaturation(back.rgb, front.rgb, front.a), blendedAlpha) * blendUniforms.uBlend;
            `
      }
    });
  }
}
/** @ignore */
SaturationBlend.extension = {
  name: "saturation",
  type: Extensions.ExtensionType.BlendMode
};

exports.SaturationBlend = SaturationBlend;
//# sourceMappingURL=SaturationBlend.js.map
