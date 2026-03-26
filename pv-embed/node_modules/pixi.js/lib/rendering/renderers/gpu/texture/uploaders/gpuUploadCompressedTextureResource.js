'use strict';

"use strict";
const blockDataMap = {
  "bc1-rgba-unorm": { blockBytes: 8, blockWidth: 4, blockHeight: 4 },
  "bc2-rgba-unorm": { blockBytes: 16, blockWidth: 4, blockHeight: 4 },
  "bc3-rgba-unorm": { blockBytes: 16, blockWidth: 4, blockHeight: 4 },
  "bc7-rgba-unorm": { blockBytes: 16, blockWidth: 4, blockHeight: 4 },
  "etc1-rgb-unorm": { blockBytes: 8, blockWidth: 4, blockHeight: 4 },
  "etc2-rgba8unorm": { blockBytes: 16, blockWidth: 4, blockHeight: 4 },
  "astc-4x4-unorm": { blockBytes: 16, blockWidth: 4, blockHeight: 4 }
};
const defaultBlockData = { blockBytes: 4, blockWidth: 1, blockHeight: 1 };
const gpuUploadCompressedTextureResource = {
  type: "compressed",
  upload(source, gpuTexture, gpu, originZOverride = 0) {
    let mipWidth = source.pixelWidth;
    let mipHeight = source.pixelHeight;
    const blockData = blockDataMap[source.format] || defaultBlockData;
    for (let i = 0; i < source.resource.length; i++) {
      const levelBuffer = source.resource[i];
      const bytesPerRow = Math.ceil(mipWidth / blockData.blockWidth) * blockData.blockBytes;
      gpu.device.queue.writeTexture(
        {
          texture: gpuTexture,
          mipLevel: i,
          origin: { x: 0, y: 0, z: originZOverride }
        },
        levelBuffer,
        {
          offset: 0,
          bytesPerRow
        },
        {
          width: Math.ceil(mipWidth / blockData.blockWidth) * blockData.blockWidth,
          height: Math.ceil(mipHeight / blockData.blockHeight) * blockData.blockHeight,
          depthOrArrayLayers: 1
        }
      );
      mipWidth = Math.max(mipWidth >> 1, 1);
      mipHeight = Math.max(mipHeight >> 1, 1);
    }
  }
};

exports.blockDataMap = blockDataMap;
exports.gpuUploadCompressedTextureResource = gpuUploadCompressedTextureResource;
//# sourceMappingURL=gpuUploadCompressedTextureResource.js.map
