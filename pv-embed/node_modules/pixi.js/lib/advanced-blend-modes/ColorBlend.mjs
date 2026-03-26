import { ExtensionType } from '../extensions/Extensions.mjs';
import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter.mjs';
import { hslgl } from '../filters/blend-modes/hls/GLhls.mjs';
import { hslgpu } from '../filters/blend-modes/hls/GPUhls.mjs';

"use strict";
class ColorBlend extends BlendModeFilter {
  constructor() {
    super({
      gl: {
        functions: `
                ${hslgl}

                vec3 blendColor(vec3 base, vec3 blend,  float opacity)
                {
                    return (setLuminosity(blend, getLuminosity(base)) * opacity + base * (1.0 - opacity));
                }
                `,
        main: `
                finalColor = vec4(blendColor(back.rgb, front.rgb,front.a), blendedAlpha) * uBlend;
                `
      },
      gpu: {
        functions: `
                ${hslgpu}

                fn blendColorOpacity(base:vec3<f32>,  blend:vec3<f32>,  opacity:f32) -> vec3<f32>
                {
                    return (setLuminosity(blend, getLuminosity(base)) * opacity + base * (1.0 - opacity));
                }
                `,
        main: `
                out = vec4<f32>(blendColorOpacity(back.rgb, front.rgb, front.a), blendedAlpha) * blendUniforms.uBlend;
                `
      }
    });
  }
}
/** @ignore */
ColorBlend.extension = {
  name: "color",
  type: ExtensionType.BlendMode
};

export { ColorBlend };
//# sourceMappingURL=ColorBlend.mjs.map
