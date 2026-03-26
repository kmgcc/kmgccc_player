'use strict';

var _const = require('./const.js');

"use strict";
function getAdjustedBlendModeBlend(blendMode, textureSource) {
  if (textureSource.alphaMode === "no-premultiply-alpha") {
    return _const.BLEND_TO_NPM[blendMode] || blendMode;
  }
  return blendMode;
}

exports.getAdjustedBlendModeBlend = getAdjustedBlendModeBlend;
//# sourceMappingURL=getAdjustedBlendModeBlend.js.map
