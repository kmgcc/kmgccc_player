'use strict';

var glFormatToGPUFormat = require('./glFormatToGPUFormat.js');
var vkFormatToGPUFormat = require('./vkFormatToGPUFormat.js');

"use strict";
function getTextureFormatFromKTXTexture(ktxTexture) {
  if (ktxTexture.classId === 2) {
    return vkFormatToGPUFormat.vkFormatToGPUFormat(ktxTexture.vkFormat);
  }
  return glFormatToGPUFormat.glFormatToGPUFormat(ktxTexture.glInternalformat);
}

exports.getTextureFormatFromKTXTexture = getTextureFormatFromKTXTexture;
//# sourceMappingURL=getTextureFormatFromKTXTexture.js.map
