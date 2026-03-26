'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var AbstractTextSystem = require('./AbstractTextSystem.js');

"use strict";
class CanvasTextSystem extends AbstractTextSystem.AbstractTextSystem {
  constructor(renderer) {
    super(renderer, false);
  }
}
/** @ignore */
CanvasTextSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem,
    Extensions.ExtensionType.WebGPUSystem
  ],
  name: "canvasText"
};

exports.CanvasTextSystem = CanvasTextSystem;
//# sourceMappingURL=GpuTextSystem.js.map
