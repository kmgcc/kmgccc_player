import { GlProgram } from '../../rendering/renderers/gl/shader/GlProgram.mjs';
import { GpuProgram } from '../../rendering/renderers/gpu/shader/GpuProgram.mjs';
import { UniformGroup } from '../../rendering/renderers/shared/shader/UniformGroup.mjs';
import { Texture } from '../../rendering/renderers/shared/texture/Texture.mjs';
import { Filter } from '../Filter.mjs';
import blendTemplateFrag from './blend-template.frag.mjs';
import blendTemplateVert from './blend-template.vert.mjs';
import blendTemplate from './blend-template.wgsl.mjs';

"use strict";
class BlendModeFilter extends Filter {
  constructor(options) {
    const gpuOptions = options.gpu;
    const gpuSource = compileBlendModeShader({ source: blendTemplate, ...gpuOptions });
    const gpuProgram = GpuProgram.from({
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
    const glSource = compileBlendModeShader({ source: blendTemplateFrag, ...glOptions });
    const glProgram = GlProgram.from({
      vertex: blendTemplateVert,
      fragment: glSource
    });
    const uniformGroup = new UniformGroup({
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
        uBackTexture: Texture.EMPTY
      }
    });
  }
}
function compileBlendModeShader(options) {
  const { source, functions, main } = options;
  return source.replace("{FUNCTIONS}", functions).replace("{MAIN}", main);
}

export { BlendModeFilter };
//# sourceMappingURL=BlendModeFilter.mjs.map
