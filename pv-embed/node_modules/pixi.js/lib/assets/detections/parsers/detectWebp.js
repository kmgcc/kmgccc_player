'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var testImageFormat = require('../utils/testImageFormat.js');

"use strict";
const detectWebp = {
  extension: {
    type: Extensions.ExtensionType.DetectionParser,
    priority: 0
  },
  test: async () => testImageFormat.testImageFormat(
    "data:image/webp;base64,UklGRh4AAABXRUJQVlA4TBEAAAAvAAAAAAfQ//73v/+BiOh/AAA="
  ),
  add: async (formats) => [...formats, "webp"],
  remove: async (formats) => formats.filter((f) => f !== "webp")
};

exports.detectWebp = detectWebp;
//# sourceMappingURL=detectWebp.js.map
