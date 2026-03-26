import { isWebGLSupported } from '../../../../../utils/browser/isWebGLSupported.mjs';
import { isWebGPUSupported } from '../../../../../utils/browser/isWebGPUSupported.mjs';
import { getSupportedGlCompressedTextureFormats } from '../../../gl/texture/utils/getSupportedGlCompressedTextureFormats.mjs';
import { getSupportedGPUCompressedTextureFormats } from '../../../gpu/texture/utils/getSupportedGPUCompressedTextureFormats.mjs';

"use strict";
let supportedCompressedTextureFormats;
async function getSupportedCompressedTextureFormats() {
  if (supportedCompressedTextureFormats !== void 0) return supportedCompressedTextureFormats;
  supportedCompressedTextureFormats = await (async () => {
    const _isWebGPUSupported = await isWebGPUSupported();
    const _isWebGLSupported = isWebGLSupported();
    if (_isWebGPUSupported && _isWebGLSupported) {
      const gpuTextureFormats = await getSupportedGPUCompressedTextureFormats();
      const glTextureFormats = getSupportedGlCompressedTextureFormats();
      return gpuTextureFormats.filter((format) => glTextureFormats.includes(format));
    } else if (_isWebGPUSupported) {
      return await getSupportedGPUCompressedTextureFormats();
    } else if (_isWebGLSupported) {
      return getSupportedGlCompressedTextureFormats();
    }
    return [];
  })();
  return supportedCompressedTextureFormats;
}

export { getSupportedCompressedTextureFormats };
//# sourceMappingURL=getSupportedCompressedTextureFormats.mjs.map
