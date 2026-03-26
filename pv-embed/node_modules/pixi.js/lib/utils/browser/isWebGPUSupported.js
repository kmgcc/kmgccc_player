'use strict';

var adapter = require('../../environment/adapter.js');

"use strict";
let _isWebGPUSupported;
async function isWebGPUSupported(options = {}) {
  if (_isWebGPUSupported !== void 0) return _isWebGPUSupported;
  _isWebGPUSupported = await (async () => {
    const gpu = adapter.DOMAdapter.get().getNavigator().gpu;
    if (!gpu) {
      return false;
    }
    try {
      const adapter = await gpu.requestAdapter(options);
      await adapter.requestDevice();
      return true;
    } catch (_e) {
      return false;
    }
  })();
  return _isWebGPUSupported;
}

exports.isWebGPUSupported = isWebGPUSupported;
//# sourceMappingURL=isWebGPUSupported.js.map
