'use strict';

var GlobalResourceRegistry = require('../../../../../utils/pool/GlobalResourceRegistry.js');
var CanvasSource = require('../sources/CanvasSource.js');
var Texture = require('../Texture.js');

"use strict";
const canvasCache = /* @__PURE__ */ new Map();
GlobalResourceRegistry.GlobalResourceRegistry.register(canvasCache);
function getCanvasTexture(canvas, options) {
  if (!canvasCache.has(canvas)) {
    const texture = new Texture.Texture({
      source: new CanvasSource.CanvasSource({
        resource: canvas,
        ...options
      })
    });
    const onDestroy = () => {
      if (canvasCache.get(canvas) === texture) {
        canvasCache.delete(canvas);
      }
    };
    texture.once("destroy", onDestroy);
    texture.source.once("destroy", onDestroy);
    canvasCache.set(canvas, texture);
  }
  return canvasCache.get(canvas);
}
function hasCachedCanvasTexture(canvas) {
  return canvasCache.has(canvas);
}

exports.getCanvasTexture = getCanvasTexture;
exports.hasCachedCanvasTexture = hasCachedCanvasTexture;
//# sourceMappingURL=getCanvasTexture.js.map
