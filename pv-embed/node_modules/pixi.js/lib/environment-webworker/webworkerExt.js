'use strict';

var Extensions = require('../extensions/Extensions.js');

"use strict";
const webworkerExt = {
  extension: {
    type: Extensions.ExtensionType.Environment,
    name: "webworker",
    priority: 0
  },
  test: () => typeof self !== "undefined" && self.WorkerGlobalScope !== void 0,
  load: async () => {
    await Promise.resolve().then(function () { return require('./webworkerAll.js'); });
  }
};

exports.webworkerExt = webworkerExt;
//# sourceMappingURL=webworkerExt.js.map
