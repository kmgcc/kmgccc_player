'use strict';

var GlProgram = require('../../rendering/renderers/gl/shader/GlProgram.js');
var GpuProgram = require('../../rendering/renderers/gpu/shader/GpuProgram.js');
var UniformGroup = require('../../rendering/renderers/shared/shader/UniformGroup.js');
var Texture = require('../../rendering/renderers/shared/texture/Texture.js');
var Filter = require('../Filter.js');
var blendTemplate$1 = require('./blend-template.frag.js');
var blendTemplate$2 = require('./blend-template.vert.js');
var blendTemplate = require('./blend-template.wgsl.js');

"use strict";
class BlendModeFilter extends Filter.Filter {
  constructor(options) {
    const gpuOptions = options.gpu;
    const gpuSource = compileBlendModeShader({ source: blendTemplate.default, ...gpuOptions });
    const gpuProgram = GpuProgram.GpuProgram.from({
      vertex: {
        source: gpuSource,
        entryPoint: "mainVertex"
      },
      fragment: {
        source: gpuSource,
        entryPoint: "mainFragment"
      }
    });
    const glOptions = options.gl;
    const glSource = compileBlendModeShader({ source: blendTemplate$1.default, ...glOptions });
    const glProgram = GlProgram.GlProgram.from({
      vertex: blendTemplate$2.default,
      fragment: glSource
    });
    const uniformGroup = new UniformGroup.UniformGroup({
      uBlend: {
        value: 1,
        type: "f32"
      }
    });
    super({
      gpuProgram,
      glProgram,
      blendRequired: true,
      resources: {
        blendUniforms: uniformGroup,
        uBackTexture: Texture.Texture.EMPTY
      }
    });
  }
}
function compileBlendModeShader(options) {
  const { source, functions, main } = options;
  return source.replace("{FUNCTIONS}", functions).replace("{MAIN}", main);
}

exports.BlendModeFilter = BlendModeFilter;
//# sourceMappingURL=BlendModeFilter.js.map
