import { GlobalResourceRegistry } from '../../../../../utils/pool/GlobalResourceRegistry.mjs';
import { CanvasSource } from '../sources/CanvasSource.mjs';
import { Texture } from '../Texture.mjs';

"use strict";
const canvasCache = /* @__PURE__ */ new Map();
GlobalResourceRegistry.register(canvasCache);
function getCanvasTexture(canvas, options) {
  if (!canvasCache.has(canvas)) {
    const texture = new Texture({
      source: new CanvasSource({
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

export { getCanvasTexture, hasCachedCanvasTexture };
//# sourceMappingURL=getCanvasTexture.mjs.map
