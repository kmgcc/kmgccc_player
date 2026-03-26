'use strict';

"use strict";
function getTextureDefaultMatrix(texture, out) {
  const { width, height } = texture.frame;
  out.scale(1 / width, 1 / height);
  return out;
}

exports.getTextureDefaultMatrix = getTextureDefaultMatrix;
//# sourceMappingURL=getTextureDefaultMatrix.js.map
