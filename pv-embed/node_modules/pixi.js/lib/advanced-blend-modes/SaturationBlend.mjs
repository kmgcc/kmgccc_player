import { ExtensionType } from '../extensions/Extensions.mjs';
import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter.mjs';
import { hslgl } from '../filters/blend-modes/hls/GLhls.mjs';
import { hslgpu } from '../filters/blend-modes/hls/GPUhls.mjs';

"use strict";
class SaturationBlend extends BlendModeFilter {
  constructor() {
    super({
      gl: {
        functions: `
                ${hslgl}

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
                ${hslgpu}

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
  type: ExtensionType.BlendMode
};

export { SaturationBlend };
//# sourceMappingURL=SaturationBlend.mjs.map
