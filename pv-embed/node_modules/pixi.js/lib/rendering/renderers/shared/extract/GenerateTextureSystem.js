'use strict';

var Color = require('../../../../color/Color.js');
var Extensions = require('../../../../extensions/Extensions.js');
var Matrix = require('../../../../maths/matrix/Matrix.js');
var Rectangle = require('../../../../maths/shapes/Rectangle.js');
var Bounds = require('../../../../scene/container/bounds/Bounds.js');
var getLocalBounds = require('../../../../scene/container/bounds/getLocalBounds.js');
var Container = require('../../../../scene/container/Container.js');
var RenderTexture = require('../texture/RenderTexture.js');

"use strict";
const tempRect = new Rectangle.Rectangle();
const tempBounds = new Bounds.Bounds();
const noColor = [0, 0, 0, 0];
class GenerateTextureSystem {
  constructor(renderer) {
    this._renderer = renderer;
  }
  /**
   * Creates a texture from a display object that can be used for creating sprites and other textures.
   * This is particularly useful for optimizing performance when a complex container needs to be reused.
   * @param options - Generate texture options or a container to convert to texture
   * @returns A new RenderTexture containing the rendered display object
   * @example
   * ```ts
   * // Basic usage with a container
   * const container = new Container();
   * container.addChild(
   *     new Graphics()
   *         .circle(0, 0, 50)
   *         .fill('red')
   * );
   *
   * const texture = renderer.textureGenerator.generateTexture(container);
   *
   * // Advanced usage with options
   * const texture = renderer.textureGenerator.generateTexture({
   *     target: container,
   *     frame: new Rectangle(0, 0, 100, 100), // Specific region
   *     resolution: 2,                        // High DPI
   *     clearColor: '#ff0000',               // Red background
   *     antialias: true                      // Smooth edges
   * });
   *
   * // Create a sprite from the generated texture
   * const sprite = new Sprite(texture);
   *
   * // Clean up when done
   * texture.destroy(true);
   * ```
   * @see {@link GenerateTextureOptions} For detailed texture generation options
   * @see {@link RenderTexture} For the type of texture created
   * @category rendering
   */
  generateTexture(options) {
    if (options instanceof Container.Container) {
      options = {
        target: options,
        frame: void 0,
        textureSourceOptions: {},
        resolution: void 0
      };
    }
    const resolution = options.resolution || this._renderer.resolution;
    const antialias = options.antialias || this._renderer.view.antialias;
    const container = options.target;
    let clearColor = options.clearColor;
    if (clearColor) {
      const isRGBAArray = Array.isArray(clearColor) && clearColor.length === 4;
      clearColor = isRGBAArray ? clearColor : Color.Color.shared.setValue(clearColor).toArray();
    } else {
      clearColor = noColor;
    }
    const region = options.frame?.copyTo(tempRect) || getLocalBounds.getLocalBounds(container, tempBounds).rectangle;
    region.width = Math.max(region.width, 1 / resolution) | 0;
    region.height = Math.max(region.height, 1 / resolution) | 0;
    const target = RenderTexture.RenderTexture.create({
      ...options.textureSourceOptions,
      width: region.width,
      height: region.height,
      resolution,
      antialias
    });
    const transform = Matrix.Matrix.shared.translate(-region.x, -region.y);
    this._renderer.render({
      container,
      transform,
      target,
      clearColor
    });
    target.source.updateMipmaps();
    return target;
  }
  destroy() {
    this._renderer = null;
  }
}
/** @ignore */
GenerateTextureSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem,
    Extensions.ExtensionType.WebGPUSystem,
    Extensions.ExtensionType.CanvasSystem
  ],
  name: "textureGenerator"
};

exports.GenerateTextureSystem = GenerateTextureSystem;
//# sourceMappingURL=GenerateTextureSystem.js.map
