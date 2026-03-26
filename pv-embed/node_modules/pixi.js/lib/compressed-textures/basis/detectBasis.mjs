import { ExtensionType } from '../../extensions/Extensions.mjs';
import { isWebGLSupported } from '../../utils/browser/isWebGLSupported.mjs';
import { isWebGPUSupported } from '../../utils/browser/isWebGPUSupported.mjs';

"use strict";
const detectBasis = {
  extension: {
    type: ExtensionType.DetectionParser,
    priority: 3
  },
  test: async () => {
    if (await isWebGPUSupported()) return true;
    if (isWebGLSupported()) return true;
    return false;
  },
  add: async (formats) => [...formats, "basis"],
  remove: async (formats) => formats.filter((f) => f !== "basis")
};

export { detectBasis };
//# sourceMappingURL=detectBasis.mjs.map
