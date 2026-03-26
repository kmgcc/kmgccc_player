'use strict';

var pixiToGlMaps = require('./pixiToGlMaps.js');

"use strict";
function applyStyleParams(style, gl, mipmaps, anisotropicExt, glFunctionName, firstParam, forceClamp, firstCreation) {
  const castParam = firstParam;
  if (!firstCreation || style.addressModeU !== "repeat" || style.addressModeV !== "repeat" || style.addressModeW !== "repeat") {
    const wrapModeS = pixiToGlMaps.wrapModeToGlAddress[forceClamp ? "clamp-to-edge" : style.addressModeU];
    const wrapModeT = pixiToGlMaps.wrapModeToGlAddress[forceClamp ? "clamp-to-edge" : style.addressModeV];
    const wrapModeR = pixiToGlMaps.wrapModeToGlAddress[forceClamp ? "clamp-to-edge" : style.addressModeW];
    gl[glFunctionName](castParam, gl.TEXTURE_WRAP_S, wrapModeS);
    gl[glFunctionName](castParam, gl.TEXTURE_WRAP_T, wrapModeT);
    if (gl.TEXTURE_WRAP_R) gl[glFunctionName](castParam, gl.TEXTURE_WRAP_R, wrapModeR);
  }
  if (!firstCreation || style.magFilter !== "linear") {
    gl[glFunctionName](castParam, gl.TEXTURE_MAG_FILTER, pixiToGlMaps.scaleModeToGlFilter[style.magFilter]);
  }
  if (mipmaps) {
    if (!firstCreation || style.mipmapFilter !== "linear") {
      const glFilterMode = pixiToGlMaps.mipmapScaleModeToGlFilter[style.minFilter][style.mipmapFilter];
      gl[glFunctionName](castParam, gl.TEXTURE_MIN_FILTER, glFilterMode);
    }
  } else {
    gl[glFunctionName](castParam, gl.TEXTURE_MIN_FILTER, pixiToGlMaps.scaleModeToGlFilter[style.minFilter]);
  }
  if (anisotropicExt && style.maxAnisotropy > 1) {
    const level = Math.min(style.maxAnisotropy, gl.getParameter(anisotropicExt.MAX_TEXTURE_MAX_ANISOTROPY_EXT));
    gl[glFunctionName](castParam, anisotropicExt.TEXTURE_MAX_ANISOTROPY_EXT, level);
  }
  if (style.compare) {
    gl[glFunctionName](castParam, gl.TEXTURE_COMPARE_FUNC, pixiToGlMaps.compareModeToGlCompare[style.compare]);
  }
}

exports.applyStyleParams = applyStyleParams;
//# sourceMappingURL=applyStyleParams.js.map
