'use strict';

var Extensions = require('../../../../extensions/Extensions.js');
var RenderTargetSystem = require('../../shared/renderTarget/RenderTargetSystem.js');
var GlRenderTargetAdaptor = require('./GlRenderTargetAdaptor.js');

"use strict";
class GlRenderTargetSystem extends RenderTargetSystem.RenderTargetSystem {
  constructor(renderer) {
    super(renderer);
    this.adaptor = new GlRenderTargetAdaptor.GlRenderTargetAdaptor();
    this.adaptor.init(renderer, this);
  }
}
/** @ignore */
GlRenderTargetSystem.extension = {
  type: [Extensions.ExtensionType.WebGLSystem],
  name: "renderTarget"
};

exports.GlRenderTargetSystem = GlRenderTargetSystem;
//# sourceMappingURL=GlRenderTargetSystem.js.map
