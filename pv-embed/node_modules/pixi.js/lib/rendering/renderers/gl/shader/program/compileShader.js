'use strict';

"use strict";
function compileShader(gl, type, src) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, src);
  gl.compileShader(shader);
  return shader;
}

exports.compileShader = compileShader;
//# sourceMappingURL=compileShader.js.map
