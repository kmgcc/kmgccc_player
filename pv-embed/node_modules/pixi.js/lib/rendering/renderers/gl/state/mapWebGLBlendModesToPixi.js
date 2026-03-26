'use strict';

var adapter = require('../../../../environment/adapter.js');

"use strict";
function mapWebGLBlendModesToPixi(gl) {
  const blendMap = {};
  blendMap.normal = [gl.ONE, gl.ONE_MINUS_SRC_ALPHA];
  blendMap.add = [gl.ONE, gl.ONE];
  blendMap.multiply = [gl.DST_COLOR, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA];
  blendMap.screen = [gl.ONE, gl.ONE_MINUS_SRC_COLOR, gl.ONE, gl.ONE_MINUS_SRC_ALPHA];
  blendMap.none = [0, 0];
  blendMap["normal-npm"] = [gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA];
  blendMap["add-npm"] = [gl.SRC_ALPHA, gl.ONE, gl.ONE, gl.ONE];
  blendMap["screen-npm"] = [gl.SRC_ALPHA, gl.ONE_MINUS_SRC_COLOR, gl.ONE, gl.ONE_MINUS_SRC_ALPHA];
  blendMap.erase = [gl.ZERO, gl.ONE_MINUS_SRC_ALPHA];
  const isWebGl2 = !(gl instanceof adapter.DOMAdapter.get().getWebGLRenderingContext());
  if (isWebGl2) {
    blendMap.min = [gl.ONE, gl.ONE, gl.ONE, gl.ONE, gl.MIN, gl.MIN];
    blendMap.max = [gl.ONE, gl.ONE, gl.ONE, gl.ONE, gl.MAX, gl.MAX];
  } else {
    const ext = gl.getExtension("EXT_blend_minmax");
    if (ext) {
      blendMap.min = [gl.ONE, gl.ONE, gl.ONE, gl.ONE, ext.MIN_EXT, ext.MIN_EXT];
      blendMap.max = [gl.ONE, gl.ONE, gl.ONE, gl.ONE, ext.MAX_EXT, ext.MAX_EXT];
    }
  }
  return blendMap;
}

exports.mapWebGLBlendModesToPixi = mapWebGLBlendModesToPixi;
//# sourceMappingURL=mapWebGLBlendModesToPixi.js.map
