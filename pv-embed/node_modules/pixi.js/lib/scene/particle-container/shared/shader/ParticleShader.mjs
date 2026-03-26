import { Color } from '../../../../color/Color.mjs';
import { Matrix } from '../../../../maths/matrix/Matrix.mjs';
import { GlProgram } from '../../../../rendering/renderers/gl/shader/GlProgram.mjs';
import { GpuProgram } from '../../../../rendering/renderers/gpu/shader/GpuProgram.mjs';
import { Shader } from '../../../../rendering/renderers/shared/shader/Shader.mjs';
import { Texture } from '../../../../rendering/renderers/shared/texture/Texture.mjs';
import { TextureStyle } from '../../../../rendering/renderers/shared/texture/TextureStyle.mjs';
import fragment from './particles.frag.mjs';
import vertex from './particles.vert.mjs';
import wgsl from './particles.wgsl.mjs';

"use strict";
class ParticleShader extends Shader {
  constructor() {
    const glProgram = GlProgram.from({
      vertex,
      fragment
    });
    const gpuProgram = GpuProgram.from({
      fragment: {
        source: wgsl,
        entryPoint: "mainFragment"
      },
      vertex: {
        source: wgsl,
        entryPoint: "mainVertex"
      }
    });
    super({
      glProgram,
      gpuProgram,
      resources: {
        // this will be replaced with the texture from the particle container
        uTexture: Texture.WHITE.source,
        // this will be replaced with the texture style from the particle container
        uSampler: new TextureStyle({}),
        // this will be replaced with the local uniforms from the particle container
        uniforms: {
          uTranslationMatrix: { value: new Matrix(), type: "mat3x3<f32>" },
          uColor: { value: new Color(16777215), type: "vec4<f32>" },
          uRound: { value: 1, type: "f32" },
          uResolution: { value: [0, 0], type: "vec2<f32>" }
        }
      }
    });
  }
}

export { ParticleShader };
//# sourceMappingURL=ParticleShader.mjs.map
