import { DOMAdapter } from '../../../../environment/adapter.mjs';

"use strict";
let canUseNewCanvasBlendModesValue;
function createColoredCanvas(color) {
  const canvas = DOMAdapter.get().createCanvas(6, 1);
  const context = canvas.getContext("2d");
  context.fillStyle = color;
  context.fillRect(0, 0, 6, 1);
  return canvas;
}
function canUseNewCanvasBlendModes() {
  if (canUseNewCanvasBlendModesValue !== void 0) {
    return canUseNewCanvasBlendModesValue;
  }
  try {
    const magenta = createColoredCanvas("#ff00ff");
    const yellow = createColoredCanvas("#ffff00");
    const canvas = DOMAdapter.get().createCanvas(6, 1);
    const context = canvas.getContext("2d");
    context.globalCompositeOperation = "multiply";
    context.drawImage(magenta, 0, 0);
    context.drawImage(yellow, 2, 0);
    const imageData = context.getImageData(2, 0, 1, 1);
    if (!imageData) {
      canUseNewCanvasBlendModesValue = false;
    } else {
      const data = imageData.data;
      canUseNewCanvasBlendModesValue = data[0] === 255 && data[1] === 0 && data[2] === 0;
    }
  } catch (_error) {
    canUseNewCanvasBlendModesValue = false;
  }
  return canUseNewCanvasBlendModesValue;
}

export { canUseNewCanvasBlendModes };
//# sourceMappingURL=canUseNewCanvasBlendModes.mjs.map
