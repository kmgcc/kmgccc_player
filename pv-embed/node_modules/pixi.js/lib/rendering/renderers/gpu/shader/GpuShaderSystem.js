'use strict';

var Extensions = require('../../../../extensions/Extensions.js');

"use strict";
class GpuShaderSystem {
  constructor() {
    this._gpuProgramData = /* @__PURE__ */ Object.create(null);
  }
  contextChange(gpu) {
    this._gpu = gpu;
  }
  getProgramData(program) {
    return this._gpuProgramData[program._layoutKey] || this._createGPUProgramData(program);
  }
  _createGPUProgramData(program) {
    const device = this._gpu.device;
    const bindGroups = program.gpuLayout.map((group) => device.createBindGroupLayout({ entries: group }));
    const pipelineLayoutDesc = { bindGroupLayouts: bindGroups };
    this._gpuProgramData[program._layoutKey] = {
      bindGroups,
      pipeline: device.createPipelineLayout(pipelineLayoutDesc)
    };
    return this._gpuProgramData[program._layoutKey];
  }
  destroy() {
    this._gpu = null;
    this._gpuProgramData = null;
  }
}
/** @ignore */
GpuShaderSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGPUSystem
  ],
  name: "shader"
};

exports.GpuShaderSystem = GpuShaderSystem;
//# sourceMappingURL=GpuShaderSystem.js.map
