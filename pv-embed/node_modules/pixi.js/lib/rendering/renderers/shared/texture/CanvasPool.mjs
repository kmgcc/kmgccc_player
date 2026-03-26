import { DOMAdapter } from '../../../../environment/adapter.mjs';
import { nextPow2 } from '../../../../maths/misc/pow2.mjs';
import { GlobalResourceRegistry } from '../../../../utils/pool/GlobalResourceRegistry.mjs';

"use strict";
class CanvasPoolClass {
  constructor(canvasOptions) {
    this._canvasPool = /* @__PURE__ */ Object.create(null);
    this.canvasOptions = canvasOptions || {};
    this.enableFullScreen = false;
  }
  /**
   * Creates texture with params that were specified in pool constructor.
   * @param pixelWidth - Width of texture in pixels.
   * @param pixelHeight - Height of texture in pixels.
   */
  _createCanvasAndContext(pixelWidth, pixelHeight) {
    const canvas = DOMAdapter.get().createCanvas();
    canvas.width = pixelWidth;
    canvas.height = pixelHeight;
    const context = canvas.getContext("2d");
    return { canvas, context };
  }
  /**
   * Gets a Power-of-Two render texture or fullScreen texture
   * @param minWidth - The minimum width of the render texture.
   * @param minHeight - The minimum height of the render texture.
   * @param resolution - The resolution of the render texture.
   * @returns The new render texture.
   */
  getOptimalCanvasAndContext(minWidth, minHeight, resolution = 1) {
    minWidth = Math.ceil(minWidth * resolution - 1e-6);
    minHeight = Math.ceil(minHeight * resolution - 1e-6);
    minWidth = nextPow2(minWidth);
    minHeight = nextPow2(minHeight);
    const key = (minWidth << 17) + (minHeight << 1);
    if (!this._canvasPool[key]) {
      this._canvasPool[key] = [];
    }
    let canvasAndContext = this._canvasPool[key].pop();
    if (!canvasAndContext) {
      canvasAndContext = this._createCanvasAndContext(minWidth, minHeight);
    }
    return canvasAndContext;
  }
  /**
   * Place a render texture back into the pool.
   * @param canvasAndContext
   */
  returnCanvasAndContext(canvasAndContext) {
    const canvas = canvasAndContext.canvas;
    const { width, height } = canvas;
    const key = (width << 17) + (height << 1);
    canvasAndContext.context.resetTransform();
    canvasAndContext.context.clearRect(0, 0, width, height);
    this._canvasPool[key].push(canvasAndContext);
  }
  clear() {
    this._canvasPool = {};
  }
}
const CanvasPool = new CanvasPoolClass();
GlobalResourceRegistry.register(CanvasPool);

export { CanvasPool, CanvasPoolClass };
//# sourceMappingURL=CanvasPool.mjs.map
