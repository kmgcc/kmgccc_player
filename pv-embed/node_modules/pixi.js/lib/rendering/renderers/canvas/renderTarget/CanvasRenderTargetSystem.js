'use strict';

var Extensions = require('../../../../extensions/Extensions.js');
var RenderTargetSystem = require('../../shared/renderTarget/RenderTargetSystem.js');
var CanvasRenderTargetAdaptor = require('./CanvasRenderTargetAdaptor.js');

"use strict";
class CanvasRenderTargetSystem extends RenderTargetSystem.RenderTargetSystem {
  constructor(renderer) {
    super(renderer);
    this.adaptor = new CanvasRenderTargetAdaptor.CanvasRenderTargetAdaptor();
    this.adaptor.init(renderer, this);
  }
}
/** @ignore */
CanvasRenderTargetSystem.extension = {
  type: [Extensions.ExtensionType.CanvasSystem],
  name: "renderTarget"
};

exports.CanvasRenderTargetSystem = CanvasRenderTargetSystem;
//# sourceMappingURL=CanvasRenderTargetSystem.js.map
