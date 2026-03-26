'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var AbstractTextSystem = require('../shared/AbstractTextSystem.js');

"use strict";
class CanvasRendererTextSystem extends AbstractTextSystem.AbstractTextSystem {
  constructor(renderer) {
    super(renderer, true);
  }
}
/** @ignore */
CanvasRendererTextSystem.extension = {
  type: [
    Extensions.ExtensionType.CanvasSystem
  ],
  name: "canvasText"
};

exports.CanvasRendererTextSystem = CanvasRendererTextSystem;
//# sourceMappingURL=CanvasTextSystem.js.map
