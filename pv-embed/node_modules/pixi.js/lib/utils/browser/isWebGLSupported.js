'use strict';

var adapter = require('../../environment/adapter.js');
var AbstractRenderer = require('../../rendering/renderers/shared/system/AbstractRenderer.js');

"use strict";
let _isWebGLSupported;
function isWebGLSupported(failIfMajorPerformanceCaveat) {
  if (_isWebGLSupported !== void 0) return _isWebGLSupported;
  _isWebGLSupported = (() => {
    const contextOptions = {
      stencil: true,
      failIfMajorPerformanceCaveat: failIfMajorPerformanceCaveat ?? AbstractRenderer.AbstractRenderer.defaultOptions.failIfMajorPerformanceCaveat
    };
    try {
      if (!adapter.DOMAdapter.get().getWebGLRenderingContext()) {
        return false;
      }
      const canvas = adapter.DOMAdapter.get().createCanvas();
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

exports.isWebGLSupported = isWebGLSupported;
//# sourceMappingURL=isWebGLSupported.js.map
