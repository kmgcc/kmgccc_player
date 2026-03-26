import { compileHighShaderGlProgram, compileHighShaderGpuProgram } from '../../high-shader/compileHighShaderToProgram.mjs';
import { colorBitGl, colorBit } from '../../high-shader/shader-bits/colorBit.mjs';
import { generateTextureBatchBitGl, generateTextureBatchBit } from '../../high-shader/shader-bits/generateTextureBatchBit.mjs';
import { roundPixelsBitGl, roundPixelsBit } from '../../high-shader/shader-bits/roundPixelsBit.mjs';
import { getBatchSamplersUniformGroup } from '../../renderers/gl/shader/getBatchSamplersUniformGroup.mjs';
import { Shader } from '../../renderers/shared/shader/Shader.mjs';

"use strict";
class DefaultShader extends Shader {
  constructor(maxTextures) {
    const glProgram = compileHighShaderGlProgram({
      name: "batch",
      bits: [
        colorBitGl,
        generateTextureBatchBitGl(maxTextures),
        roundPixelsBitGl
      ]
    });
    const gpuProgram = compileHighShaderGpuProgram({
      name: "batch",
      bits: [
        colorBit,
        generateTextureBatchBit(maxTextures),
        roundPixelsBit
      ]
    });
    super({
      glProgram,
      gpuProgram,
      resources: {
        batchSamplers: getBatchSamplersUniformGroup(maxTextures)
      }
    });
    this.maxTextures = maxTextures;
  }
}

export { DefaultShader };
//# sourceMappingURL=DefaultShader.mjs.map
