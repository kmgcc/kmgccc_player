import { ExtensionType } from '../../../extensions/Extensions.mjs';

"use strict";
class CanvasLimitsSystem {
  constructor() {
    this.maxTextures = 16;
    this.maxBatchableTextures = 16;
    this.maxUniformBindings = 0;
  }
  init() {
  }
}
/** @ignore */
CanvasLimitsSystem.extension = {
  type: [
    ExtensionType.CanvasSystem
  ],
  name: "limits"
};

export { CanvasLimitsSystem };
//# sourceMappingURL=CanvasLimitsSystem.mjs.map
