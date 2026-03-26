'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var _const = require('../shared/state/const.js');

"use strict";
class GpuStencilSystem {
  constructor(renderer) {
    this._renderTargetStencilState = /* @__PURE__ */ Object.create(null);
    this._renderer = renderer;
    renderer.renderTarget.onRenderTargetChange.add(this);
  }
  onRenderTargetChange(renderTarget) {
    let stencilState = this._renderTargetStencilState[renderTarget.uid];
    if (!stencilState) {
      stencilState = this._renderTargetStencilState[renderTarget.uid] = {
        stencilMode: _const.STENCIL_MODES.DISABLED,
        stencilReference: 0
      };
    }
    this._activeRenderTarget = renderTarget;
    this.setStencilMode(stencilState.stencilMode, stencilState.stencilReference);
  }
  setStencilMode(stencilMode, stencilReference) {
    const stencilState = this._renderTargetStencilState[this._activeRenderTarget.uid];
    stencilState.stencilMode = stencilMode;
    stencilState.stencilReference = stencilReference;
    const renderer = this._renderer;
    renderer.pipeline.setStencilMode(stencilMode);
    renderer.encoder.renderPassEncoder.setStencilReference(stencilReference);
  }
  destroy() {
    this._renderer.renderTarget.onRenderTargetChange.remove(this);
    this._renderer = null;
    this._activeRenderTarget = null;
    this._renderTargetStencilState = null;
  }
}
/** @ignore */
GpuStencilSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGPUSystem
  ],
  name: "stencil"
};

exports.GpuStencilSystem = GpuStencilSystem;
//# sourceMappingURL=GpuStencilSystem.js.map
