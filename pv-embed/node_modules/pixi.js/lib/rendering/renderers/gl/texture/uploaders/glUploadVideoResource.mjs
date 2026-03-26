import { isSafari } from '../../../../../utils/browser/isSafari.mjs';
import { glUploadImageResource } from './glUploadImageResource.mjs';

"use strict";
const defaultForceAllocation = isSafari();
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
    glUploadImageResource.upload(source, glTexture, gl, webGLVersion, targetOverride, forceAllocation);
  }
};

export { glUploadVideoResource };
//# sourceMappingURL=glUploadVideoResource.mjs.map
