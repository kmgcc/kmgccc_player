"use strict";
function isRenderingToScreen(renderTarget) {
  const resource = renderTarget.colorTexture.source.resource;
  return globalThis.HTMLCanvasElement && resource instanceof HTMLCanvasElement && document.body.contains(resource);
}

export { isRenderingToScreen };
//# sourceMappingURL=isRenderingToScreen.mjs.map
