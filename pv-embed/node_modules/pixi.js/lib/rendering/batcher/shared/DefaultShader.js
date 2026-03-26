'use strict';

var compileHighShaderToProgram = require('../../high-shader/compileHighShaderToProgram.js');
var colorBit = require('../../high-shader/shader-bits/colorBit.js');
var generateTextureBatchBit = require('../../high-shader/shader-bits/generateTextureBatchBit.js');
var roundPixelsBit = require('../../high-shader/shader-bits/roundPixelsBit.js');
var getBatchSamplersUniformGroup = require('../../renderers/gl/shader/getBatchSamplersUniformGroup.js');
var Shader = require('../../renderers/shared/shader/Shader.js');

"use strict";
class DefaultShader extends Shader.Shader {
  constructor(maxTextures) {
    const glProgram = compileHighShaderToProgram.compileHighShaderGlProgram({
      name: "batch",
      bits: [
        colorBit.colorBitGl,
        generateTextureBatchBit.generateTextureBatchBitGl(maxTextures),
        roundPixelsBit.roundPixelsBitGl
      ]
    });
    const gpuProgram = compileHighShaderToProgram.compileHighShaderGpuProgram({
      name: "batch",
      bits: [
        colorBit.colorBit,
        generateTextureBatchBit.generateTextureBatchBit(maxTextures),
        roundPixelsBit.roundPixelsBit
      ]
    });
    super({
      glProgram,
      gpuProgram,
      resources: {
        batchSamplers: getBatchSamplersUniformGroup.getBatchSamplersUniformGroup(maxTextures)
      }
    });
    this.maxTextures = maxTextures;
  }
}

exports.DefaultShader = DefaultShader;
//# sourceMappingURL=DefaultShader.js.map
