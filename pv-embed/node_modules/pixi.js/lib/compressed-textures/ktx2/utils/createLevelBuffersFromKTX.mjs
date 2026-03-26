"use strict";
function createLevelBuffersFromKTX(ktxTexture) {
  const levelBuffers = [];
  for (let i = 0; i < ktxTexture.numLevels; i++) {
    const imageData = ktxTexture.getImageData(i, 0, 0);
    const levelBuffer = new Uint8Array(imageData.byteLength);
    levelBuffer.set(imageData);
    levelBuffers.push(levelBuffer);
  }
  return levelBuffers;
}

export { createLevelBuffersFromKTX };
//# sourceMappingURL=createLevelBuffersFromKTX.mjs.map
