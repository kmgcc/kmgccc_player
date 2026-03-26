'use strict';

"use strict";
const gpuUploadBufferImageResource = {
  type: "image",
  upload(source, gpuTexture, gpu, originZOverride = 0) {
    const resource = source.resource;
    const total = (source.pixelWidth | 0) * (source.pixelHeight | 0);
    const bytesPerPixel = resource.byteLength / total;
    gpu.device.queue.writeTexture(
      { texture: gpuTexture, origin: { x: 0, y: 0, z: originZOverride } },
      resource,
      {
        offset: 0,
        rowsPerImage: source.pixelHeight,
        bytesPerRow: source.pixelWidth * bytesPerPixel
      },
      {
        width: source.pixelWidth,
        height: source.pixelHeight,
        depthOrArrayLayers: 1
      }
    );
  }
};

exports.gpuUploadBufferImageResource = gpuUploadBufferImageResource;
//# sourceMappingURL=gpuUploadBufferImageResource.js.map
