"use strict";
function generateLayout(maxTextures) {
  const layout = {};
  let bindIndex = 0;
  for (let i = 0; i < maxTextures; i++) {
    layout[`textureSource${i + 1}`] = bindIndex++;
    layout[`textureSampler${i + 1}`] = bindIndex++;
  }
  return layout;
}

export { generateLayout };
//# sourceMappingURL=generateLayout.mjs.map
