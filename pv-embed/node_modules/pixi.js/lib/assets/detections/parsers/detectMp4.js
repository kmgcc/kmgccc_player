'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var testVideoFormat = require('../utils/testVideoFormat.js');

"use strict";
const detectMp4 = {
  extension: {
    type: Extensions.ExtensionType.DetectionParser,
    priority: 0
  },
  test: async () => testVideoFormat.testVideoFormat("video/mp4"),
  add: async (formats) => [...formats, "mp4", "m4v"],
  remove: async (formats) => formats.filter((f) => f !== "mp4" && f !== "m4v")
};

exports.detectMp4 = detectMp4;
//# sourceMappingURL=detectMp4.js.map
