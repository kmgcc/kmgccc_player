'use strict';

var definedProps = require('../container/utils/definedProps.js');
var Mesh = require('../mesh/shared/Mesh.js');
var RopeGeometry = require('./RopeGeometry.js');

"use strict";
const _MeshRope = class _MeshRope extends Mesh.Mesh {
  /**
   * Note: The wrap mode of the texture is set to REPEAT if `textureScale` is positive.
   * @param options
   * @param options.texture - The texture to use on the rope.
   * @param options.points - An array of {@link math.Point} objects to construct this rope.
   * @param {number} options.textureScale - Optional. Positive values scale rope texture
   * keeping its aspect ratio. You can reduce alpha channel artifacts by providing a larger texture
   * and downsampling here. If set to zero, texture will be stretched instead.
   */
  constructor(options) {
    const { texture, points, textureScale, ...rest } = { ..._MeshRope.defaultOptions, ...options };
    const ropeGeometry = new RopeGeometry.RopeGeometry(definedProps.definedProps({ width: texture.height, points, textureScale }));
    if (textureScale > 0) {
      texture.source.style.addressMode = "repeat";
    }
    super(definedProps.definedProps({
      ...rest,
      texture,
      geometry: ropeGeometry
    }));
    this.autoUpdate = true;
    this.onRender = this._render;
  }
  _render() {
    const geometry = this.geometry;
    if (this.autoUpdate || geometry._width !== this.texture.height) {
      geometry._width = this.texture.height;
      geometry.update();
    }
  }
};
/**
 * Default options for creating a MeshRope instance. These values are used when specific
 * options aren't provided in the constructor.
 * @example
 * ```ts
 * // Use default options globally
 * MeshRope.defaultOptions = {
 *     textureScale: 0.5  // Set higher quality texture scaling
 * };
 *
 * // Create rope with modified defaults
 * const rope = new MeshRope({
 *     texture: Texture.from('rope.png'),
 *     points: [
 *         new Point(0, 0),
 *         new Point(100, 0)
 *     ]
 * }); // Will use textureScale: 0.5
 * ```
 * @property {number} textureScale - Controls texture scaling along the rope (0 = stretch)
 * @see {@link MeshRopeOptions} For all available options
 */
_MeshRope.defaultOptions = {
  textureScale: 0
};
let MeshRope = _MeshRope;

exports.MeshRope = MeshRope;
//# sourceMappingURL=MeshRope.js.map
