import { DOMAdapter } from '../../environment/adapter.mjs';
import { AbstractRenderer } from '../../rendering/renderers/shared/system/AbstractRenderer.mjs';

"use strict";
let _isWebGLSupported;
function isWebGLSupported(failIfMajorPerformanceCaveat) {
  if (_isWebGLSupported !== void 0) return _isWebGLSupported;
  _isWebGLSupported = (() => {
    const contextOptions = {
      stencil: true,
      failIfMajorPerformanceCaveat: failIfMajorPerformanceCaveat ?? AbstractRenderer.defaultOptions.failIfMajorPerformanceCaveat
    };
    try {
      if (!DOMAdapter.get().getWebGLRenderingContext()) {
        return false;
      }
      const canvas = DOMAdapter.get().createCanvas();
      let gl = canvas.getContext("webgl", contextOptions);
      const success = !!gl?.getContextAttributes()?.stencil;
      if (gl) {
        const loseContext = gl.getExtension("WEBGL_lose_context");
        if (loseContext) {
          loseContext.loseContext();
        }
      }
      gl = null;
      return success;
    } catch (_e) {
      return false;
    }
  })();
  return _isWebGLSupported;
}

export { isWebGLSupported };
//# sourceMappingURL=isWebGLSupported.mjs.map
