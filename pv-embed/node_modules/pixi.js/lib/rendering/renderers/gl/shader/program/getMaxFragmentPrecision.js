'use strict';

var getTestContext = require('./getTestContext.js');

"use strict";
let maxFragmentPrecision;
function getMaxFragmentPrecision() {
  if (!maxFragmentPrecision) {
    maxFragmentPrecision = "mediump";
    const gl = getTestContext.getTestContext();
    if (gl) {
      if (gl.getShaderPrecisionFormat) {
        const shaderFragment = gl.getShaderPrecisionFormat(gl.FRAGMENT_SHADER, gl.HIGH_FLOAT);
        maxFragmentPrecision = shaderFragment.precision ? "highp" : "mediump";
      }
    }
  }
  return maxFragmentPrecision;
}

exports.getMaxFragmentPrecision = getMaxFragmentPrecision;
//# sourceMappingURL=getMaxFragmentPrecision.js.map
