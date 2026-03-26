import { Matrix } from '../../../maths/matrix/Matrix.mjs';
import { compileHighShaderGpuProgram, compileHighShaderGlProgram } from '../../../rendering/high-shader/compileHighShaderToProgram.mjs';
import { colorBit, colorBitGl } from '../../../rendering/high-shader/shader-bits/colorBit.mjs';
import { generateTextureBatchBit, generateTextureBatchBitGl } from '../../../rendering/high-shader/shader-bits/generateTextureBatchBit.mjs';
import { roundPixelsBit, roundPixelsBitGl } from '../../../rendering/high-shader/shader-bits/roundPixelsBit.mjs';
import { getBatchSamplersUniformGroup } from '../../../rendering/renderers/gl/shader/getBatchSamplersUniformGroup.mjs';
import { Shader } from '../../../rendering/renderers/shared/shader/Shader.mjs';
import { UniformGroup } from '../../../rendering/renderers/shared/shader/UniformGroup.mjs';
import { localUniformMSDFBit, localUniformMSDFBitGl } from './shader-bits/localUniformMSDFBit.mjs';
import { mSDFBit, mSDFBitGl } from './shader-bits/mSDFBit.mjs';

"use strict";
let gpuProgram;
let glProgram;
class SdfShader extends Shader {
  constructor(maxTextures) {
    const uniforms = new UniformGroup({
      uColor: { value: new Float32Array([1, 1, 1, 1]), type: "vec4<f32>" },
      uTransformMatrix: { value: new Matrix(), type: "mat3x3<f32>" },
      uDistance: { value: 4, type: "f32" },
      uRound: { value: 0, type: "f32" }
    });
    gpuProgram ?? (gpuProgram = compileHighShaderGpuProgram({
      name: "sdf-shader",
      bits: [
        colorBit,
        generateTextureBatchBit(maxTextures),
        localUniformMSDFBit,
        mSDFBit,
        roundPixelsBit
      ]
    }));
    glProgram ?? (glProgram = compileHighShaderGlProgram({
      name: "sdf-shader",
      bits: [
        colorBitGl,
        generateTextureBatchBitGl(maxTextures),
        localUniformMSDFBitGl,
        mSDFBitGl,
        roundPixelsBitGl
      ]
    }));
    super({
      glProgram,
      gpuProgram,
      resources: {
        localUniforms: uniforms,
        batchSamplers: getBatchSamplersUniformGroup(maxTextures)
      }
    });
  }
}

export { SdfShader };
//# sourceMappingURL=SdfShader.mjs.map
