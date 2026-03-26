'use strict';

var CanvasPool = require('../../../rendering/renderers/shared/texture/CanvasPool.js');

"use strict";
function getTemporaryCanvasFromImage(image, resolution) {
  const canvasAndContext = CanvasPool.CanvasPool.getOptimalCanvasAndContext(
    image.width,
    image.height,
    resolution
  );
  const { context } = canvasAndContext;
  context.clearRect(0, 0, image.width, image.height);
  context.drawImage(image, 0, 0);
  return canvasAndContext;
}

exports.getTemporaryCanvasFromImage = getTemporaryCanvasFromImage;
//# sourceMappingURL=getTemporaryCanvasFromImage.js.map
