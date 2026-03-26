import { BLEND_TO_NPM } from './const.mjs';

"use strict";
function getAdjustedBlendModeBlend(blendMode, textureSource) {
  if (textureSource.alphaMode === "no-premultiply-alpha") {
    return BLEND_TO_NPM[blendMode] || blendMode;
  }
  return blendMode;
}

export { getAdjustedBlendModeBlend };
//# sourceMappingURL=getAdjustedBlendModeBlend.mjs.map
