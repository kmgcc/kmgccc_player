'use strict';

var defaultValue = require('./defaultValue.js');
var mapType = require('./mapType.js');

"use strict";
function getUniformData(program, gl) {
  const uniforms = {};
  const totalUniforms = gl.getProgramParameter(program, gl.ACTIVE_UNIFORMS);
  for (let i = 0; i < totalUniforms; i++) {
    const uniformData = gl.getActiveUniform(program, i);
    const name = uniformData.name.replace(/\[.*?\]$/, "");
    const isArray = !!uniformData.name.match(/\[.*?\]$/);
    const type = mapType.mapType(gl, uniformData.type);
    uniforms[name] = {
      name,
      index: i,
      type,
      size: uniformData.size,
      isArray,
      value: defaultValue.defaultValue(type, uniformData.size)
    };
  }
  return uniforms;
}

exports.getUniformData = getUniformData;
//# sourceMappingURL=getUniformData.js.map
