"use strict";
const vkFormatToGPUFormatMap = {
  23: "rgb8unorm",
  // VK_FORMAT_R8G8B8_UNORM
  37: "rgba8unorm",
  // VK_FORMAT_R8G8B8A8_UNORM
  43: "rgba8unorm-srgb"
  // VK_FORMAT_R8G8B8A8_SRGB
  // TODO add more!
};
function vkFormatToGPUFormat(vkFormat) {
  const format = vkFormatToGPUFormatMap[vkFormat];
  if (format) {
    return format;
  }
  throw new Error(`Unsupported VkFormat: ${vkFormat}`);
}

export { vkFormatToGPUFormat };
//# sourceMappingURL=vkFormatToGPUFormat.mjs.map
