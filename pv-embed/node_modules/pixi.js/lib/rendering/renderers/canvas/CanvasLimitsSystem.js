'use strict';

var Extensions = require('../../../extensions/Extensions.js');

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
    Extensions.ExtensionType.CanvasSystem
  ],
  name: "limits"
};

exports.CanvasLimitsSystem = CanvasLimitsSystem;
//# sourceMappingURL=CanvasLimitsSystem.js.map
