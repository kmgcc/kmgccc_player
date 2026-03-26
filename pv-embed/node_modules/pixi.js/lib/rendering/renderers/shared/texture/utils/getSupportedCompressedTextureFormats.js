'use strict';

var isWebGLSupported = require('../../../../../utils/browser/isWebGLSupported.js');
var isWebGPUSupported = require('../../../../../utils/browser/isWebGPUSupported.js');
var getSupportedGlCompressedTextureFormats = require('../../../gl/texture/utils/getSupportedGlCompressedTextureFormats.js');
var getSupportedGPUCompressedTextureFormats = require('../../../gpu/texture/utils/getSupportedGPUCompressedTextureFormats.js');

"use strict";
let supportedCompressedTextureFormats;
async function getSupportedCompressedTextureFormats() {
  if (supportedCompressedTextureFormats !== void 0) return supportedCompressedTextureFormats;
  supportedCompressedTextureFormats = await (async () => {
    const _isWebGPUSupported = await isWebGPUSupported.isWebGPUSupported();
    const _isWebGLSupported = isWebGLSupported.isWebGLSupported();
    if (_isWebGPUSupported && _isWebGLSupported) {
      const gpuTextureFormats = await getSupportedGPUCompressedTextureFormats.getSupportedGPUCompressedTextureFormats();
      const glTextureFormats = getSupportedGlCompressedTextureFormats.getSupportedGlCompressedTextureFormats();
      return gpuTextureFormats.filter((format) => glTextureFormats.includes(format));
    } else if (_isWebGPUSupported) {
      return await getSupportedGPUCompressedTextureFormats.getSupportedGPUCompressedTextureFormats();
    } else if (_isWebGLSupported) {
      return getSupportedGlCompressedTextureFormats.getSupportedGlCompressedTextureFormats();
    }
    return [];
  })();
  return supportedCompressedTextureFormats;
}

exports.getSupportedCompressedTextureFormats = getSupportedCompressedTextureFormats;
//# sourceMappingURL=getSupportedCompressedTextureFormats.js.map
