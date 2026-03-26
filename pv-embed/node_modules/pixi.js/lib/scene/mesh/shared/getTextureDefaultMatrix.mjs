"use strict";
function getTextureDefaultMatrix(texture, out) {
  const { width, height } = texture.frame;
  out.scale(1 / width, 1 / height);
  return out;
}

export { getTextureDefaultMatrix };
//# sourceMappingURL=getTextureDefaultMatrix.mjs.map
