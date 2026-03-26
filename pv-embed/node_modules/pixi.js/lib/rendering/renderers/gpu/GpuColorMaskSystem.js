'use strict';

var Extensions = require('../../../extensions/Extensions.js');

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
    Extensions.ExtensionType.WebGPUSystem
  ],
  name: "colorMask"
};

exports.GpuColorMaskSystem = GpuColorMaskSystem;
//# sourceMappingURL=GpuColorMaskSystem.js.map
