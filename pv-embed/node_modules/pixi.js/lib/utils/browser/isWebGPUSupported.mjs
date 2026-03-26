import { DOMAdapter } from '../../environment/adapter.mjs';

"use strict";
let _isWebGPUSupported;
async function isWebGPUSupported(options = {}) {
  if (_isWebGPUSupported !== void 0) return _isWebGPUSupported;
  _isWebGPUSupported = await (async () => {
    const gpu = DOMAdapter.get().getNavigator().gpu;
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

export { isWebGPUSupported };
//# sourceMappingURL=isWebGPUSupported.mjs.map
