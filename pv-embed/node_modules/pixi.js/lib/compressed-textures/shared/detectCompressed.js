'use strict';

var Extensions = require('../../extensions/Extensions.js');
var getSupportedCompressedTextureFormats = require('../../rendering/renderers/shared/texture/utils/getSupportedCompressedTextureFormats.js');
var isWebGLSupported = require('../../utils/browser/isWebGLSupported.js');
var isWebGPUSupported = require('../../utils/browser/isWebGPUSupported.js');
var resolveCompressedTextureUrl = require('./resolveCompressedTextureUrl.js');

"use strict";
let compressedTextureExtensions;
const detectCompressed = {
  extension: {
    type: Extensions.ExtensionType.DetectionParser,
    priority: 2
  },
  test: async () => {
    if (await isWebGPUSupported.isWebGPUSupported()) return true;
    if (isWebGLSupported.isWebGLSupported()) return true;
    return false;
  },
  add: async (formats) => {
    const supportedCompressedTextureFormats = await getSupportedCompressedTextureFormats.getSupportedCompressedTextureFormats();
    compressedTextureExtensions = extractExtensionsForCompressedTextureFormats(supportedCompressedTextureFormats);
    return [...compressedTextureExtensions, ...formats];
  },
  remove: async (formats) => {
    if (compressedTextureExtensions) {
      return formats.filter((f) => !(f in compressedTextureExtensions));
    }
    return formats;
  }
};
function extractExtensionsForCompressedTextureFormats(formats) {
  const extensions = ["basis"];
  const dupeMap = {};
  formats.forEach((format) => {
    const extension = format.split("-")[0];
    if (extension && !dupeMap[extension]) {
      dupeMap[extension] = true;
      extensions.push(extension);
    }
  });
  extensions.sort((a, b) => {
    const aIndex = resolveCompressedTextureUrl.validFormats.indexOf(a);
    const bIndex = resolveCompressedTextureUrl.validFormats.indexOf(b);
    if (aIndex === -1) {
      return 1;
    }
    if (bIndex === -1) {
      return -1;
    }
    return aIndex - bIndex;
  });
  return extensions;
}

exports.detectCompressed = detectCompressed;
//# sourceMappingURL=detectCompressed.js.map
