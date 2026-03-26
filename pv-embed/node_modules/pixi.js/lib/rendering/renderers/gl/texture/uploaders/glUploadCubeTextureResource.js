'use strict';

var _const = require('../const.js');

"use strict";
const FACE_ORDER = ["right", "left", "top", "bottom", "front", "back"];
function createGlUploadCubeTextureResource(uploaders) {
  return {
    id: "cube",
    upload(source, glTexture, gl, webGLVersion) {
      const faces = source.faces;
      for (let faceIndex = 0; faceIndex < FACE_ORDER.length; faceIndex++) {
        const key = FACE_ORDER[faceIndex];
        const face = faces[key];
        const uploader = uploaders[face.uploadMethodId] || uploaders.image;
        uploader.upload(
          face,
          glTexture,
          gl,
          webGLVersion,
          // Use the face target for the current face. cube faces ids go up 1 so
          // GL_TARGETS.TEXTURE_CUBE_MAP_POSITIVE_X + i addresses the i'th face target.
          _const.GL_TARGETS.TEXTURE_CUBE_MAP_POSITIVE_X + faceIndex,
          // Force allocation for the first upload of each face.
          (glTexture._layerInitMask & 1 << faceIndex) === 0
        );
        glTexture._layerInitMask |= 1 << faceIndex;
      }
      glTexture.width = source.pixelWidth;
      glTexture.height = source.pixelHeight;
    }
  };
}

exports.createGlUploadCubeTextureResource = createGlUploadCubeTextureResource;
//# sourceMappingURL=glUploadCubeTextureResource.js.map
