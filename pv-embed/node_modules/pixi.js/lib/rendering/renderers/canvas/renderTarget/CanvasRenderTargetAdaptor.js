'use strict';

var Color = require('../../../../color/Color.js');
var adapter = require('../../../../environment/adapter.js');
var CanvasSource = require('../../shared/texture/sources/CanvasSource.js');

"use strict";
class CanvasRenderTargetAdaptor {
  /**
   * Initializes the adaptor.
   * @param renderer - Canvas renderer instance.
   * @param renderTargetSystem - The render target system.
   * @advanced
   */
  init(renderer, renderTargetSystem) {
    this._renderer = renderer;
    this._renderTargetSystem = renderTargetSystem;
  }
  /**
   * Creates a GPU render target for canvas.
   * @param renderTarget - Render target to initialize.
   * @advanced
   */
  initGpuRenderTarget(renderTarget) {
    const colorTexture = renderTarget.colorTexture;
    const { canvas, context } = this._ensureCanvas(colorTexture);
    return {
      canvas,
      context,
      width: canvas.width,
      height: canvas.height
    };
  }
  /**
   * Resizes the backing canvas for a render target.
   * @param renderTarget - Render target to resize.
   * @advanced
   */
  resizeGpuRenderTarget(renderTarget) {
    const colorTexture = renderTarget.colorTexture;
    const { canvas } = this._ensureCanvas(colorTexture);
    canvas.width = renderTarget.pixelWidth;
    canvas.height = renderTarget.pixelHeight;
  }
  /**
   * Starts a render pass on the canvas target.
   * @param renderTarget - Target to render to.
   * @param clear - Clear mode.
   * @param clearColor - Optional clear color.
   * @param viewport - Optional viewport.
   * @advanced
   */
  startRenderPass(renderTarget, clear, clearColor, viewport) {
    const gpuRenderTarget = this._renderTargetSystem.getGpuRenderTarget(renderTarget);
    this._renderer.canvasContext.activeContext = gpuRenderTarget.context;
    this._renderer.canvasContext.activeResolution = renderTarget.resolution;
    if (clear) {
      this.clear(renderTarget, clear, clearColor, viewport);
    }
  }
  /**
   * Clears the render target.
   * @param renderTarget - Target to clear.
   * @param _clear - Clear mode (unused).
   * @param clearColor - Optional clear color.
   * @param viewport - Optional viewport rectangle.
   * @advanced
   */
  clear(renderTarget, _clear, clearColor, viewport) {
    const gpuRenderTarget = this._renderTargetSystem.getGpuRenderTarget(renderTarget);
    const context = gpuRenderTarget.context;
    const bounds = viewport || { x: 0, y: 0, width: renderTarget.pixelWidth, height: renderTarget.pixelHeight };
    context.setTransform(1, 0, 0, 1, 0, 0);
    context.clearRect(bounds.x, bounds.y, bounds.width, bounds.height);
    if (clearColor) {
      const color = Color.Color.shared.setValue(clearColor);
      if (color.alpha > 0) {
        context.globalAlpha = color.alpha;
        context.fillStyle = color.toHex();
        context.fillRect(bounds.x, bounds.y, bounds.width, bounds.height);
        context.globalAlpha = 1;
      }
    }
  }
  /**
   * Finishes the render pass (no-op for canvas).
   * @advanced
   */
  finishRenderPass() {
  }
  /**
   * Copies a render target into a texture source.
   * @param {RenderTarget} sourceRenderSurfaceTexture - Source render target.
   * @param {Texture} destinationTexture - Destination texture.
   * @param {object} originSrc - Source origin.
   * @param {number} originSrc.x - Source x origin.
   * @param {number} originSrc.y - Source y origin.
   * @param {object} size - Copy size.
   * @param {number} size.width - Copy width.
   * @param {number} size.height - Copy height.
   * @param {object} [originDest] - Destination origin.
   * @param {number} originDest.x - Destination x origin.
   * @param {number} originDest.y - Destination y origin.
   * @advanced
   */
  copyToTexture(sourceRenderSurfaceTexture, destinationTexture, originSrc, size, originDest) {
    const sourceGpuTarget = this._renderTargetSystem.getGpuRenderTarget(sourceRenderSurfaceTexture);
    const sourceCanvas = sourceGpuTarget.canvas;
    const destSource = destinationTexture.source;
    const { context } = this._ensureCanvas(destSource);
    const dx = originDest?.x ?? 0;
    const dy = originDest?.y ?? 0;
    context.drawImage(
      sourceCanvas,
      originSrc.x,
      originSrc.y,
      size.width,
      size.height,
      dx,
      dy,
      size.width,
      size.height
    );
    destSource.update();
    return destinationTexture;
  }
  /**
   * Destroys a GPU render target (no-op for canvas).
   * @param _gpuRenderTarget - Target to destroy.
   * @advanced
   */
  destroyGpuRenderTarget(_gpuRenderTarget) {
  }
  _ensureCanvas(source) {
    let canvas = source.resource;
    if (!canvas || !CanvasSource.CanvasSource.test(canvas)) {
      canvas = adapter.DOMAdapter.get().createCanvas(source.pixelWidth, source.pixelHeight);
      source.resource = canvas;
    }
    if (canvas.width !== source.pixelWidth || canvas.height !== source.pixelHeight) {
      canvas.width = source.pixelWidth;
      canvas.height = source.pixelHeight;
    }
    const context = canvas.getContext("2d");
    return { canvas, context };
  }
}

exports.CanvasRenderTargetAdaptor = CanvasRenderTargetAdaptor;
//# sourceMappingURL=CanvasRenderTargetAdaptor.js.map
