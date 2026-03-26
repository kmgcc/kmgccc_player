"use strict";
function createLevelBuffers(basisTexture, basisTranscoderFormat) {
  const images = basisTexture.getNumImages();
  const levels = basisTexture.getNumLevels(0);
  const success = basisTexture.startTranscoding();
  if (!success) {
    throw new Error("startTranscoding failed");
  }
  const levelBuffers = [];
  for (let levelIndex = 0; levelIndex < levels; ++levelIndex) {
    for (let sliceIndex = 0; sliceIndex < images; ++sliceIndex) {
      const transcodeSize = basisTexture.getImageTranscodedSizeInBytes(sliceIndex, levelIndex, basisTranscoderFormat);
      const levelBuffer = new Uint8Array(transcodeSize);
      const success2 = basisTexture.transcodeImage(levelBuffer, sliceIndex, levelIndex, basisTranscoderFormat, 1, 0);
      if (!success2) {
        throw new Error("transcodeImage failed");
      }
      levelBuffers.push(levelBuffer);
    }
  }
  return levelBuffers;
}

export { createLevelBuffers };
//# sourceMappingURL=createLevelBuffers.mjs.map
