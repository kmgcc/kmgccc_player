import { GlProgram } from '../renderers/gl/shader/GlProgram.mjs';
import { GpuProgram } from '../renderers/gpu/shader/GpuProgram.mjs';
import { compileHighShader, compileHighShaderGl } from './compiler/compileHighShader.mjs';
import { vertexGPUTemplate, fragmentGPUTemplate, fragmentGlTemplate, vertexGlTemplate } from './defaultProgramTemplate.mjs';
import { globalUniformsBit, globalUniformsBitGl } from './shader-bits/globalUniformsBit.mjs';

"use strict";
function compileHighShaderGpuProgram({ bits, name }) {
  const source = compileHighShader({
    template: {
      fragment: fragmentGPUTemplate,
      vertex: vertexGPUTemplate
    },
    bits: [
      globalUniformsBit,
      ...bits
    ]
  });
  return GpuProgram.from({
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
  return new GlProgram({
    name,
    ...compileHighShaderGl({
      template: {
        vertex: vertexGlTemplate,
        fragment: fragmentGlTemplate
      },
      bits: [
        globalUniformsBitGl,
        ...bits
      ]
    })
  });
}

export { compileHighShaderGlProgram, compileHighShaderGpuProgram };
//# sourceMappingURL=compileHighShaderToProgram.mjs.map
