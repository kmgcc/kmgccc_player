'use strict';

var Extensions = require('../../extensions/Extensions.js');
var isWebGLSupported = require('../../utils/browser/isWebGLSupported.js');
var isWebGPUSupported = require('../../utils/browser/isWebGPUSupported.js');

"use strict";
const detectBasis = {
  extension: {
    type: Extensions.ExtensionType.DetectionParser,
    priority: 3
  },
  test: async () => {
    if (await isWebGPUSupported.isWebGPUSupported()) return true;
    if (isWebGLSupported.isWebGLSupported()) return true;
    return false;
  },
  add: async (formats) => [...formats, "basis"],
  remove: async (formats) => formats.filter((f) => f !== "basis")
};

exports.detectBasis = detectBasis;
//# sourceMappingURL=detectBasis.js.map
