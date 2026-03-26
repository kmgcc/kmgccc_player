'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var testVideoFormat = require('../utils/testVideoFormat.js');

"use strict";
const detectWebm = {
  extension: {
    type: Extensions.ExtensionType.DetectionParser,
    priority: 0
  },
  test: async () => testVideoFormat.testVideoFormat("video/webm"),
  add: async (formats) => [...formats, "webm"],
  remove: async (formats) => formats.filter((f) => f !== "webm")
};

exports.detectWebm = detectWebm;
//# sourceMappingURL=detectWebm.js.map
