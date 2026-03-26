'use strict';

"use strict";
const glUploadBufferImageResource = {
  id: "buffer",
  upload(source, glTexture, gl, _webGLVersion, targetOverride, forceAllocation = false) {
    const target = targetOverride || glTexture.target;
    if (!forceAllocation && (glTexture.width === source.width && glTexture.height === source.height)) {
      gl.texSubImage2D(
        target,
        0,
        0,
        0,
        source.width,
        source.height,
        glTexture.format,
        glTexture.type,
        source.resource
      );
    } else {
      gl.texImage2D(
        target,
        0,
        glTexture.internalFormat,
        source.width,
        source.height,
        0,
        glTexture.format,
        glTexture.type,
        source.resource
      );
    }
    glTexture.width = source.width;
    glTexture.height = source.height;
  }
};

exports.glUploadBufferImageResource = glUploadBufferImageResource;
//# sourceMappingURL=glUploadBufferImageResource.js.map
