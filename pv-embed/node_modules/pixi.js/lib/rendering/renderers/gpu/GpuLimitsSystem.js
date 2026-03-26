'use strict';

var Extensions = require('../../../extensions/Extensions.js');

"use strict";
class GpuLimitsSystem {
  constructor(renderer) {
    this._renderer = renderer;
  }
  contextChange() {
    this.maxTextures = this._renderer.device.gpu.device.limits.maxSampledTexturesPerShaderStage;
    this.maxBatchableTextures = this.maxTextures;
  }
  destroy() {
  }
}
/** @ignore */
GpuLimitsSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGPUSystem
  ],
  name: "limits"
};

exports.GpuLimitsSystem = GpuLimitsSystem;
//# sourceMappingURL=GpuLimitsSystem.js.map
