'use strict';

var adapter = require('../../../../../environment/adapter.js');

"use strict";
let context;
function getTestContext() {
  if (!context || context?.isContextLost()) {
    const canvas = adapter.DOMAdapter.get().createCanvas();
    context = canvas.getContext("webgl", {});
  }
  return context;
}

exports.getTestContext = getTestContext;
//# sourceMappingURL=getTestContext.js.map
