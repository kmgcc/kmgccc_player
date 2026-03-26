import { GlProgram } from '../../../rendering/renderers/gl/shader/GlProgram.mjs';
import { GpuProgram } from '../../../rendering/renderers/gpu/shader/GpuProgram.mjs';
import { Filter } from '../../Filter.mjs';
import vertex from '../defaultFilter.vert.mjs';
import fragment from './passthrough.frag.mjs';
import source from './passthrough.wgsl.mjs';

"use strict";
class PassthroughFilter extends Filter {
  constructor() {
    const gpuProgram = GpuProgram.from({
      vertex: { source, entryPoint: "mainVertex" },
      fragment: { source, entryPoint: "mainFragment" },
      name: "passthrough-filter"
    });
    const glProgram = GlProgram.from({
      vertex,
      fragment,
      name: "passthrough-filter"
    });
    super({
      gpuProgram,
      glProgram
    });
  }
}

export { PassthroughFilter };
//# sourceMappingURL=PassthroughFilter.mjs.map
