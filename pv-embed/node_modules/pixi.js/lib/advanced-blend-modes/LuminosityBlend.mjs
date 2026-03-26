import { ExtensionType } from '../extensions/Extensions.mjs';
import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter.mjs';
import { hslgl } from '../filters/blend-modes/hls/GLhls.mjs';
import { hslgpu } from '../filters/blend-modes/hls/GPUhls.mjs';

"use strict";
class LuminosityBlend extends BlendModeFilter {
  constructor() {
    super({
      gl: {
        functions: `
                ${hslgl}

                vec3 blendLuminosity(vec3 base, vec3 blend,  float opacity)
                {
                    vec3 blendLuminosity = setLuminosity(base, getLuminosity(blend));
                    return (blendLuminosity * opacity + base * (1.0 - opacity));
                }
                `,
        main: `
                finalColor = vec4(blendLuminosity(back.rgb, front.rgb,front.a), blendedAlpha) * uBlend;
                `
      },
      gpu: {
        functions: `
                ${hslgpu}

                fn blendLuminosity(base:vec3<f32>,  blend:vec3<f32>,  opacity:f32) -> vec3<f32>
                {
                    let blendLuminosity: vec3<f32> = setLuminosity(base, getLuminosity(blend));
                    return (blendLuminosity * opacity + base * (1.0 - opacity));
                }
            `,
        main: `
                out = vec4<f32>(blendLuminosity(back.rgb, front.rgb, front.a), blendedAlpha) * blendUniforms.uBlend;
            `
      }
    });
  }
}
/** @ignore */
LuminosityBlend.extension = {
  name: "luminosity",
  type: ExtensionType.BlendMode
};

export { LuminosityBlend };
//# sourceMappingURL=LuminosityBlend.mjs.map
