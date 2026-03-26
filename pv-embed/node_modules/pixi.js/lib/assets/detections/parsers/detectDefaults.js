'use strict';

var Extensions = require('../../../extensions/Extensions.js');

"use strict";
const imageFormats = ["png", "jpg", "jpeg"];
const detectDefaults = {
  extension: {
    type: Extensions.ExtensionType.DetectionParser,
    priority: -1
  },
  test: () => Promise.resolve(true),
  add: async (formats) => [...formats, ...imageFormats],
  remove: async (formats) => formats.filter((f) => !imageFormats.includes(f))
};

exports.detectDefaults = detectDefaults;
//# sourceMappingURL=detectDefaults.js.map
