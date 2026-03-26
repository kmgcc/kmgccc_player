import { ExtensionType } from '../../../extensions/Extensions.mjs';

"use strict";
class GpuColorMaskSystem {
  constructor(renderer) {
    this._colorMaskCache = 15;
    this._renderer = renderer;
  }
  setMask(colorMask) {
    if (this._colorMaskCache === colorMask) return;
    this._colorMaskCache = colorMask;
    this._renderer.pipeline.setColorMask(colorMask);
  }
  destroy() {
    this._renderer = null;
    this._colorMaskCache = null;
  }
}
/** @ignore */
GpuColorMaskSystem.extension = {
  type: [
    ExtensionType.WebGPUSystem
  ],
  name: "colorMask"
};

export { GpuColorMaskSystem };
//# sourceMappingURL=GpuColorMaskSystem.mjs.map
