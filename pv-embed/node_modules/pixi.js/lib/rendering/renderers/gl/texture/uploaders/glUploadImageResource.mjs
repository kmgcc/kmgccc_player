"use strict";
const glUploadImageResource = {
  id: "image",
  upload(source, glTexture, gl, webGLVersion, targetOverride, forceAllocation = false) {
    const target = targetOverride || glTexture.target;
    const textureWidth = source.pixelWidth;
    const textureHeight = source.pixelHeight;
    const resourceWidth = source.resourceWidth;
    const resourceHeight = source.resourceHeight;
    const isWebGL2 = webGLVersion === 2;
    const needsAllocation = forceAllocation || glTexture.width !== textureWidth || glTexture.height !== textureHeight;
    const resourceFitsTexture = resourceWidth >= textureWidth && resourceHeight >= textureHeight;
    const resource = source.resource;
    const uploadFunction = isWebGL2 ? uploadImageWebGL2 : uploadImageWebGL1;
    uploadFunction(
      gl,
      target,
      glTexture,
      textureWidth,
      textureHeight,
      resourceWidth,
      resourceHeight,
      resource,
      needsAllocation,
      resourceFitsTexture
    );
    glTexture.width = textureWidth;
    glTexture.height = textureHeight;
  }
};
function uploadImageWebGL2(gl, target, glTexture, textureWidth, textureHeight, resourceWidth, resourceHeight, resource, needsAllocation, resourceFitsTexture) {
  if (!resourceFitsTexture) {
    if (needsAllocation) {
      gl.texImage2D(
        target,
        0,
        glTexture.internalFormat,
        textureWidth,
        textureHeight,
        0,
        glTexture.format,
        glTexture.type,
        null
      );
    }
    gl.texSubImage2D(
      target,
      0,
      0,
      0,
      resourceWidth,
      resourceHeight,
      glTexture.format,
      glTexture.type,
      resource
    );
    return;
  }
  if (!needsAllocation) {
    gl.texSubImage2D(
      target,
      0,
      0,
      0,
      glTexture.format,
      glTexture.type,
      resource
    );
    return;
  }
  gl.texImage2D(
    target,
    0,
    glTexture.internalFormat,
    textureWidth,
    textureHeight,
    0,
    glTexture.format,
    glTexture.type,
    resource
  );
}
function uploadImageWebGL1(gl, target, glTexture, textureWidth, textureHeight, _resourceWidth, _resourceHeight, resource, needsAllocation, resourceFitsTexture) {
  if (!resourceFitsTexture) {
    if (needsAllocation) {
      gl.texImage2D(
        target,
        0,
        glTexture.internalFormat,
        textureWidth,
        textureHeight,
        0,
        glTexture.format,
        glTexture.type,
        null
      );
    }
    gl.texSubImage2D(
      target,
      0,
      0,
      0,
      glTexture.format,
      glTexture.type,
      resource
    );
    return;
  }
  if (!needsAllocation) {
    gl.texSubImage2D(
      target,
      0,
      0,
      0,
      glTexture.format,
      glTexture.type,
      resource
    );
    return;
  }
  gl.texImage2D(
    target,
    0,
    glTexture.internalFormat,
    glTexture.format,
    glTexture.type,
    resource
  );
}

export { glUploadImageResource };
//# sourceMappingURL=glUploadImageResource.mjs.map
