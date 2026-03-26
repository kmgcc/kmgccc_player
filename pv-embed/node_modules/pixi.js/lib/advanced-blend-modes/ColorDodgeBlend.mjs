import { ExtensionType } from '../extensions/Extensions.mjs';
import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter.mjs';

"use strict";
class ColorDodgeBlend extends BlendModeFilter {
  constructor() {
    super({
      gl: {
        functions: `
                float colorDodge(float base, float blend)
                {
                    return base / (1.0 - blend);
                }

                vec3 blendColorDodge(vec3 base, vec3 blend, float opacity)
                {
                    vec3 blended = vec3(
                        colorDodge(base.r, blend.r),
                        colorDodge(base.g, blend.g),
                        colorDodge(base.b, blend.b)
                    );

                    return (blended * opacity + base * (1.0 - opacity));
                }
                `,
        main: `
                finalColor = vec4(blendColorDodge(back.rgb, front.rgb,front.a), blendedAlpha) * uBlend;
                `
      },
      gpu: {
        functions: `
                fn colorDodge(base: f32, blend: f32) -> f32
                {
                    return base / (1.0 - blend);
                }

                fn blendColorDodge(base: vec3<f32>, blend: vec3<f32>, opacity: f32) -> vec3<f32>
                {
                    let blended = vec3<f32>(
                        colorDodge(base.r, blend.r),
                        colorDodge(base.g, blend.g),
                        colorDodge(base.b, blend.b)
                    );

                    return (blended * opacity + base * (1.0 - opacity));
                }
                `,
        main: `
                    out = vec4<f32>(blendColorDodge(back.rgb, front.rgb, front.a), blendedAlpha) * blendUniforms.uBlend;
                `
      }
    });
  }
}
/** @ignore */
ColorDodgeBlend.extension = {
  name: "color-dodge",
  type: ExtensionType.BlendMode
};

export { ColorDodgeBlend };
//# sourceMappingURL=ColorDodgeBlend.mjs.map
