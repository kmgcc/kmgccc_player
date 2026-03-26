import { CanvasPool } from '../../../rendering/renderers/shared/texture/CanvasPool.mjs';

"use strict";
function getTemporaryCanvasFromImage(image, resolution) {
  const canvasAndContext = CanvasPool.getOptimalCanvasAndContext(
    image.width,
    image.height,
    resolution
  );
  const { context } = canvasAndContext;
  context.clearRect(0, 0, image.width, image.height);
  context.drawImage(image, 0, 0);
  return canvasAndContext;
}

export { getTemporaryCanvasFromImage };
//# sourceMappingURL=getTemporaryCanvasFromImage.mjs.map
