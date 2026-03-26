import { ExtensionType } from '../../../extensions/Extensions.mjs';

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
    ExtensionType.WebGPUSystem
  ],
  name: "limits"
};

export { GpuLimitsSystem };
//# sourceMappingURL=GpuLimitsSystem.mjs.map
