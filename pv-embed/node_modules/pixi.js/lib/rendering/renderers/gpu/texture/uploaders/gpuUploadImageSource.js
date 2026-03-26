'use strict';

var adapter = require('../../../../../environment/adapter.js');
var warn = require('../../../../../utils/logging/warn.js');

"use strict";
const gpuUploadImageResource = {
  type: "image",
  upload(source, gpuTexture, gpu, originZOverride = 0) {
    const resource = source.resource;
    if (!resource) return;
    if (globalThis.HTMLImageElement && resource instanceof HTMLImageElement) {
      const canvas = adapter.DOMAdapter.get().createCanvas(resource.width, resource.height);
      const context = canvas.getContext("2d");
      context.drawImage(resource, 0, 0, resource.width, resource.height);
      source.resource = canvas;
      warn.warn("ImageSource: Image element passed, converting to canvas and replacing resource.");
    }
    const width = Math.min(gpuTexture.width, source.resourceWidth || source.pixelWidth);
    const height = Math.min(gpuTexture.height, source.resourceHeight || source.pixelHeight);
    const premultipliedAlpha = source.alphaMode === "premultiply-alpha-on-upload";
    gpu.device.queue.copyExternalImageToTexture(
      { source: resource },
      { texture: gpuTexture, origin: { x: 0, y: 0, z: originZOverride }, premultipliedAlpha },
      {
        width,
        height
      }
    );
  }
};

exports.gpuUploadImageResource = gpuUploadImageResource;
//# sourceMappingURL=gpuUploadImageSource.js.map
