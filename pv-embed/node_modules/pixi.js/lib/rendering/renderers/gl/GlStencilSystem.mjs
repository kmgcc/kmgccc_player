import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { GpuStencilModesToPixi } from '../gpu/state/GpuStencilModesToPixi.mjs';
import { STENCIL_MODES } from '../shared/state/const.mjs';

"use strict";
class GlStencilSystem {
  constructor(renderer) {
    this._stencilCache = {
      enabled: false,
      stencilReference: 0,
      stencilMode: STENCIL_MODES.NONE
    };
    this._renderTargetStencilState = /* @__PURE__ */ Object.create(null);
    renderer.renderTarget.onRenderTargetChange.add(this);
  }
  contextChange(gl) {
    this._gl = gl;
    this._comparisonFuncMapping = {
      always: gl.ALWAYS,
      never: gl.NEVER,
      equal: gl.EQUAL,
      "not-equal": gl.NOTEQUAL,
      less: gl.LESS,
      "less-equal": gl.LEQUAL,
      greater: gl.GREATER,
      "greater-equal": gl.GEQUAL
    };
    this._stencilOpsMapping = {
      keep: gl.KEEP,
      zero: gl.ZERO,
      replace: gl.REPLACE,
      invert: gl.INVERT,
      "increment-clamp": gl.INCR,
      "decrement-clamp": gl.DECR,
      "increment-wrap": gl.INCR_WRAP,
      "decrement-wrap": gl.DECR_WRAP
    };
    this.resetState();
  }
  onRenderTargetChange(renderTarget) {
    if (this._activeRenderTarget === renderTarget) return;
    this._activeRenderTarget = renderTarget;
    let stencilState = this._renderTargetStencilState[renderTarget.uid];
    if (!stencilState) {
      stencilState = this._renderTargetStencilState[renderTarget.uid] = {
        stencilMode: STENCIL_MODES.DISABLED,
        stencilReference: 0
      };
    }
    this.setStencilMode(stencilState.stencilMode, stencilState.stencilReference);
  }
  resetState() {
    this._stencilCache.enabled = false;
    this._stencilCache.stencilMode = STENCIL_MODES.NONE;
    this._stencilCache.stencilReference = 0;
  }
  setStencilMode(stencilMode, stencilReference) {
    const stencilState = this._renderTargetStencilState[this._activeRenderTarget.uid];
    const gl = this._gl;
    const mode = GpuStencilModesToPixi[stencilMode];
    const _stencilCache = this._stencilCache;
    stencilState.stencilMode = stencilMode;
    stencilState.stencilReference = stencilReference;
    if (stencilMode === STENCIL_MODES.DISABLED) {
      if (this._stencilCache.enabled) {
        this._stencilCache.enabled = false;
        gl.disable(gl.STENCIL_TEST);
      }
      return;
    }
    if (!this._stencilCache.enabled) {
      this._stencilCache.enabled = true;
      gl.enable(gl.STENCIL_TEST);
    }
    if (stencilMode !== _stencilCache.stencilMode || _stencilCache.stencilReference !== stencilReference) {
      _stencilCache.stencilMode = stencilMode;
      _stencilCache.stencilReference = stencilReference;
      gl.stencilFunc(this._comparisonFuncMapping[mode.stencilBack.compare], stencilReference, 255);
      gl.stencilOp(gl.KEEP, gl.KEEP, this._stencilOpsMapping[mode.stencilBack.passOp]);
    }
  }
}
/** @ignore */
GlStencilSystem.extension = {
  type: [
    ExtensionType.WebGLSystem
  ],
  name: "stencil"
};

export { GlStencilSystem };
//# sourceMappingURL=GlStencilSystem.mjs.map
