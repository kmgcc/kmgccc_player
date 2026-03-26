'use strict';

var GlProgram = require('../../../rendering/renderers/gl/shader/GlProgram.js');
var GpuProgram = require('../../../rendering/renderers/gpu/shader/GpuProgram.js');
var Filter = require('../../Filter.js');
var defaultFilter = require('../defaultFilter.vert.js');
var passthrough$1 = require('./passthrough.frag.js');
var passthrough = require('./passthrough.wgsl.js');

"use strict";
class PassthroughFilter extends Filter.Filter {
  constructor() {
    const gpuProgram = GpuProgram.GpuProgram.from({
      vertex: { source: passthrough.default, entryPoint: "mainVertex" },
      fragment: { source: passthrough.default, entryPoint: "mainFragment" },
      name: "passthrough-filter"
    });
    const glProgram = GlProgram.GlProgram.from({
      vertex: defaultFilter.default,
      fragment: passthrough$1.default,
      name: "passthrough-filter"
    });
    super({
      gpuProgram,
      glProgram
    });
  }
}

exports.PassthroughFilter = PassthroughFilter;
//# sourceMappingURL=PassthroughFilter.js.map
