'use strict';

var isSafari = require('../../../../../utils/browser/isSafari.js');
var glUploadImageResource = require('./glUploadImageResource.js');

"use strict";
const defaultForceAllocation = isSafari.isSafari();
const glUploadVideoResource = {
  id: "video",
  upload(source, glTexture, gl, webGLVersion, targetOverride, forceAllocation = defaultForceAllocation) {
    if (!source.isValid) {
      const target = targetOverride ?? glTexture.target;
      gl.texImage2D(
        target,
        0,
        glTexture.internalFormat,
        1,
        1,
        0,
        glTexture.format,
        glTexture.type,
        null
      );
      return;
    }
    glUploadImageResource.glUploadImageResource.upload(source, glTexture, gl, webGLVersion, targetOverride, forceAllocation);
  }
};

exports.glUploadVideoResource = glUploadVideoResource;
//# sourceMappingURL=glUploadVideoResource.js.map
