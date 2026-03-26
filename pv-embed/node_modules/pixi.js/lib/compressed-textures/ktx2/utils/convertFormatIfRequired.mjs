"use strict";
const converters = {
  rgb8unorm: {
    convertedFormat: "rgba8unorm",
    convertFunction: convertRGBtoRGBA
  },
  "rgb8unorm-srgb": {
    convertedFormat: "rgba8unorm-srgb",
    convertFunction: convertRGBtoRGBA
  }
};
function convertFormatIfRequired(textureOptions) {
  const format = textureOptions.format;
  if (converters[format]) {
    const convertFunction = converters[format].convertFunction;
    const levelBuffers = textureOptions.resource;
    for (let i = 0; i < levelBuffers.length; i++) {
      levelBuffers[i] = convertFunction(levelBuffers[i]);
    }
    textureOptions.format = converters[format].convertedFormat;
  }
}
function convertRGBtoRGBA(levelBuffer) {
  const pixelCount = levelBuffer.byteLength / 3;
  const levelBufferWithAlpha = new Uint32Array(pixelCount);
  for (let i = 0; i < pixelCount; ++i) {
    levelBufferWithAlpha[i] = levelBuffer[i * 3] + (levelBuffer[i * 3 + 1] << 8) + (levelBuffer[i * 3 + 2] << 16) + 4278190080;
  }
  return new Uint8Array(levelBufferWithAlpha.buffer);
}

export { convertFormatIfRequired };
//# sourceMappingURL=convertFormatIfRequired.mjs.map
