'use strict';

"use strict";
const FACE_ORDER = ["right", "left", "top", "bottom", "front", "back"];
function createGpuUploadCubeTextureResource(uploaders) {
  return {
    type: "cube",
    upload(source, gpuTexture, gpu) {
      const faces = source.faces;
      for (let i = 0; i < FACE_ORDER.length; i++) {
        const key = FACE_ORDER[i];
        const face = faces[key];
        const uploader = uploaders[face.uploadMethodId] || uploaders.image;
        uploader.upload(face, gpuTexture, gpu, i);
      }
    }
  };
}

exports.createGpuUploadCubeTextureResource = createGpuUploadCubeTextureResource;
//# sourceMappingURL=gpuUploadCubeTextureResource.js.map
