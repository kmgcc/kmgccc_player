'use strict';

var adapter = require('../../../../environment/adapter.js');
var Extensions = require('../../../../extensions/Extensions.js');
var canvasUtils = require('../utils/canvasUtils.js');

"use strict";
class CanvasTextureSystem {
  /**
   * @param renderer - The owning CanvasRenderer.
   */
  constructor(renderer) {
    void renderer;
  }
  /** Initializes the system (no-op for canvas). */
  init() {
  }
  /**
   * Initializes a texture source (no-op for canvas).
   * @param _source - Texture source.
   */
  initSource(_source) {
  }
  /**
   * Creates a canvas containing the texture's frame.
   * @param texture - Texture to render.
   */
  generateCanvas(texture) {
    const canvas = adapter.DOMAdapter.get().createCanvas();
    const context = canvas.getContext("2d");
    const source = canvasUtils.canvasUtils.getCanvasSource(texture);
    if (!source) {
      return canvas;
    }
    const frame = texture.frame;
    const resolution = texture.source._resolution ?? texture.source.resolution ?? 1;
    const sx = frame.x * resolution;
    const sy = frame.y * resolution;
    const sw = frame.width * resolution;
    const sh = frame.height * resolution;
    canvas.width = Math.ceil(sw);
    canvas.height = Math.ceil(sh);
    context.drawImage(
      source,
      sx,
      sy,
      sw,
      sh,
      0,
      0,
      sw,
      sh
    );
    return canvas;
  }
  /**
   * Reads pixel data from a texture.
   * @param texture - Texture to read.
   */
  getPixels(texture) {
    const canvas = this.generateCanvas(texture);
    const context = canvas.getContext("2d", { willReadFrequently: true });
    const imageData = context.getImageData(0, 0, canvas.width, canvas.height);
    return {
      pixels: imageData.data,
      width: canvas.width,
      height: canvas.height
    };
  }
  /** Destroys the system (no-op for canvas). */
  destroy() {
  }
}
/** @ignore */
CanvasTextureSystem.extension = {
  type: [
    Extensions.ExtensionType.CanvasSystem
  ],
  name: "texture"
};

exports.CanvasTextureSystem = CanvasTextureSystem;
//# sourceMappingURL=CanvasTextureSystem.js.map
