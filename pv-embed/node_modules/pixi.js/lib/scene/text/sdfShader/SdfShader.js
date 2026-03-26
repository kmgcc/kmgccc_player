'use strict';

var Matrix = require('../../../maths/matrix/Matrix.js');
var compileHighShaderToProgram = require('../../../rendering/high-shader/compileHighShaderToProgram.js');
var colorBit = require('../../../rendering/high-shader/shader-bits/colorBit.js');
var generateTextureBatchBit = require('../../../rendering/high-shader/shader-bits/generateTextureBatchBit.js');
var roundPixelsBit = require('../../../rendering/high-shader/shader-bits/roundPixelsBit.js');
var getBatchSamplersUniformGroup = require('../../../rendering/renderers/gl/shader/getBatchSamplersUniformGroup.js');
var Shader = require('../../../rendering/renderers/shared/shader/Shader.js');
var UniformGroup = require('../../../rendering/renderers/shared/shader/UniformGroup.js');
var localUniformMSDFBit = require('./shader-bits/localUniformMSDFBit.js');
var mSDFBit = require('./shader-bits/mSDFBit.js');

"use strict";
let gpuProgram;
let glProgram;
class SdfShader extends Shader.Shader {
  constructor(maxTextures) {
    const uniforms = new UniformGroup.UniformGroup({
      uColor: { value: new Float32Array([1, 1, 1, 1]), type: "vec4<f32>" },
      uTransformMatrix: { value: new Matrix.Matrix(), type: "mat3x3<f32>" },
      uDistance: { value: 4, type: "f32" },
      uRound: { value: 0, type: "f32" }
    });
    gpuProgram ?? (gpuProgram = compileHighShaderToProgram.compileHighShaderGpuProgram({
      name: "sdf-shader",
      bits: [
        colorBit.colorBit,
        generateTextureBatchBit.generateTextureBatchBit(maxTextures),
        localUniformMSDFBit.localUniformMSDFBit,
        mSDFBit.mSDFBit,
        roundPixelsBit.roundPixelsBit
      ]
    }));
    glProgram ?? (glProgram = compileHighShaderToProgram.compileHighShaderGlProgram({
      name: "sdf-shader",
      bits: [
        colorBit.colorBitGl,
        generateTextureBatchBit.generateTextureBatchBitGl(maxTextures),
        localUniformMSDFBit.localUniformMSDFBitGl,
        mSDFBit.mSDFBitGl,
        roundPixelsBit.roundPixelsBitGl
      ]
    }));
    super({
      glProgram,
      gpuProgram,
      resources: {
        localUniforms: uniforms,
        batchSamplers: getBatchSamplersUniformGroup.getBatchSamplersUniformGroup(maxTextures)
      }
    });
  }
}

exports.SdfShader = SdfShader;
//# sourceMappingURL=SdfShader.js.map
