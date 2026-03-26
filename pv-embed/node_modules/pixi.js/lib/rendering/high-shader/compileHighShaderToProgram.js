'use strict';

var GlProgram = require('../renderers/gl/shader/GlProgram.js');
var GpuProgram = require('../renderers/gpu/shader/GpuProgram.js');
var compileHighShader = require('./compiler/compileHighShader.js');
var defaultProgramTemplate = require('./defaultProgramTemplate.js');
var globalUniformsBit = require('./shader-bits/globalUniformsBit.js');

"use strict";
function compileHighShaderGpuProgram({ bits, name }) {
  const source = compileHighShader.compileHighShader({
    template: {
      fragment: defaultProgramTemplate.fragmentGPUTemplate,
      vertex: defaultProgramTemplate.vertexGPUTemplate
    },
    bits: [
      globalUniformsBit.globalUniformsBit,
      ...bits
    ]
  });
  return GpuProgram.GpuProgram.from({
    name,
    vertex: {
      source: source.vertex,
      entryPoint: "main"
    },
    fragment: {
      source: source.fragment,
      entryPoint: "main"
    }
  });
}
function compileHighShaderGlProgram({ bits, name }) {
  return new GlProgram.GlProgram({
    name,
    ...compileHighShader.compileHighShaderGl({
      template: {
        vertex: defaultProgramTemplate.vertexGlTemplate,
        fragment: defaultProgramTemplate.fragmentGlTemplate
      },
      bits: [
        globalUniformsBit.globalUniformsBitGl,
        ...bits
      ]
    })
  });
}

exports.compileHighShaderGlProgram = compileHighShaderGlProgram;
exports.compileHighShaderGpuProgram = compileHighShaderGpuProgram;
//# sourceMappingURL=compileHighShaderToProgram.js.map
