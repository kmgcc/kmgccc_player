'use strict';

var Extensions = require('../../../../extensions/Extensions.js');
var RenderTargetSystem = require('../../shared/renderTarget/RenderTargetSystem.js');
var GpuRenderTargetAdaptor = require('./GpuRenderTargetAdaptor.js');

"use strict";
class GpuRenderTargetSystem extends RenderTargetSystem.RenderTargetSystem {
  constructor(renderer) {
    super(renderer);
    this.adaptor = new GpuRenderTargetAdaptor.GpuRenderTargetAdaptor();
    this.adaptor.init(renderer, this);
  }
}
/** @ignore */
GpuRenderTargetSystem.extension = {
  type: [Extensions.ExtensionType.WebGPUSystem],
  name: "renderTarget"
};

exports.GpuRenderTargetSystem = GpuRenderTargetSystem;
//# sourceMappingURL=GpuRenderTargetSystem.js.map
