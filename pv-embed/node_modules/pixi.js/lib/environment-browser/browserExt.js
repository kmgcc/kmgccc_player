'use strict';

var Extensions = require('../extensions/Extensions.js');

"use strict";
const browserExt = {
  extension: {
    type: Extensions.ExtensionType.Environment,
    name: "browser",
    priority: -1
  },
  test: () => true,
  load: async () => {
    await Promise.resolve().then(function () { return require('./browserAll.js'); });
  }
};

exports.browserExt = browserExt;
//# sourceMappingURL=browserExt.js.map
