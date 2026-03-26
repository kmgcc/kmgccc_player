import { ExtensionType } from '../extensions/Extensions.mjs';
import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter.mjs';

"use strict";
class DarkenBlend extends BlendModeFilter {
  constructor() {
    super({
      gl: {
        functions: `
                vec3 blendDarken(vec3 base, vec3 blend, float opacity)
                {
                    return (min(base, blend) * opacity + base * (1.0 - opacity));
                }
                `,
        main: `
                finalColor = vec4(blendDarken(back.rgb, front.rgb,front.a), blendedAlpha) * uBlend;
                `
      },
      gpu: {
        functions: `
                fn blendDarken(base:vec3<f32>,  blend:vec3<f32>,  opacity:f32) -> vec3<f32>
                {
                    return (min(blend,base) * opacity + base * (1.0 - opacity));
                }
                `,
        main: `
                out = vec4<f32>(blendDarken(back.rgb, front.rgb, front.a), blendedAlpha) * blendUniforms.uBlend;
                `
      }
    });
  }
}
/** @ignore */
DarkenBlend.extension = {
  name: "darken",
  type: ExtensionType.BlendMode
};

export { DarkenBlend };
//# sourceMappingURL=DarkenBlend.mjs.map
