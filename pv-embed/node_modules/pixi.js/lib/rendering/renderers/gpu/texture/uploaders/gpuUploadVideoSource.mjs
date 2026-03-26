import { gpuUploadImageResource } from './gpuUploadImageSource.mjs';

"use strict";
const gpuUploadVideoResource = {
  type: "video",
  upload(source, gpuTexture, gpu, originZOverride) {
    gpuUploadImageResource.upload(source, gpuTexture, gpu, originZOverride);
  }
};

export { gpuUploadVideoResource };
//# sourceMappingURL=gpuUploadVideoSource.mjs.map
