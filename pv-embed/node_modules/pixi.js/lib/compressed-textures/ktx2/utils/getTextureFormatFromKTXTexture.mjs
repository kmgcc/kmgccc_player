import { glFormatToGPUFormat } from './glFormatToGPUFormat.mjs';
import { vkFormatToGPUFormat } from './vkFormatToGPUFormat.mjs';

"use strict";
function getTextureFormatFromKTXTexture(ktxTexture) {
  if (ktxTexture.classId === 2) {
    return vkFormatToGPUFormat(ktxTexture.vkFormat);
  }
  return glFormatToGPUFormat(ktxTexture.glInternalformat);
}

export { getTextureFormatFromKTXTexture };
//# sourceMappingURL=getTextureFormatFromKTXTexture.mjs.map
