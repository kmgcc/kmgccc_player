import { ExtensionType } from '../../extensions/Extensions.mjs';
import { getSupportedCompressedTextureFormats } from '../../rendering/renderers/shared/texture/utils/getSupportedCompressedTextureFormats.mjs';
import { isWebGLSupported } from '../../utils/browser/isWebGLSupported.mjs';
import { isWebGPUSupported } from '../../utils/browser/isWebGPUSupported.mjs';
import { validFormats } from './resolveCompressedTextureUrl.mjs';

"use strict";
let compressedTextureExtensions;
const detectCompressed = {
  extension: {
    type: ExtensionType.DetectionParser,
    priority: 2
  },
  test: async () => {
    if (await isWebGPUSupported()) return true;
    if (isWebGLSupported()) return true;
    return false;
  },
  add: async (formats) => {
    const supportedCompressedTextureFormats = await getSupportedCompressedTextureFormats();
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
    const aIndex = validFormats.indexOf(a);
    const bIndex = validFormats.indexOf(b);
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

export { detectCompressed };
//# sourceMappingURL=detectCompressed.mjs.map
