'use strict';

var gpuUploadImageSource = require('./gpuUploadImageSource.js');

"use strict";
const gpuUploadVideoResource = {
  type: "video",
  upload(source, gpuTexture, gpu, originZOverride) {
    gpuUploadImageSource.gpuUploadImageResource.upload(source, gpuTexture, gpu, originZOverride);
  }
};

exports.gpuUploadVideoResource = gpuUploadVideoResource;
//# sourceMappingURL=gpuUploadVideoSource.js.map
