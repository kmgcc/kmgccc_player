'use strict';

var TextureSource = require('./sources/TextureSource.js');
var Texture = require('./Texture.js');

"use strict";
class RenderTexture extends Texture.Texture {
  /**
   * Creates a RenderTexture. Pass `dynamic: true` in options to allow resizing after creation.
   * @param options - Options for the RenderTexture, including width, height, and dynamic.
   * @returns A new RenderTexture instance.
   * @example
   * const rt = RenderTexture.create({ width: 100, height: 100, dynamic: true });
   * rt.resize(500, 500);
   */
  static create(options) {
    const { dynamic, ...rest } = options;
    return new RenderTexture({
      source: new TextureSource.TextureSource(rest),
      dynamic: dynamic ?? false
    });
  }
  /**
   * Resizes the render texture.
   * @param width - The new width of the render texture.
   * @param height - The new height of the render texture.
   * @param resolution - The new resolution of the render texture.
   * @returns This texture.
   */
  resize(width, height, resolution) {
    this.source.resize(width, height, resolution);
    return this;
  }
}

exports.RenderTexture = RenderTexture;
//# sourceMappingURL=RenderTexture.js.map
