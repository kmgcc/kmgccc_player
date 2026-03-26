import { Texture } from '../../rendering/renderers/shared/texture/Texture.mjs';
import { definedProps } from '../container/utils/definedProps.mjs';
import { Mesh } from '../mesh/shared/Mesh.mjs';
import { PerspectivePlaneGeometry } from './PerspectivePlaneGeometry.mjs';

"use strict";
const _PerspectiveMesh = class _PerspectiveMesh extends Mesh {
  /**
   * @param options - Options to be applied to PerspectiveMesh
   */
  constructor(options) {
    options = { ..._PerspectiveMesh.defaultOptions, ...options };
    const { texture, verticesX, verticesY, ...rest } = options;
    const planeGeometry = new PerspectivePlaneGeometry(definedProps({
      width: texture.width,
      height: texture.height,
      verticesX,
      verticesY
    }));
    super(definedProps({ ...rest, geometry: planeGeometry }));
    this._texture = texture;
    this.geometry.setCorners(
      options.x0,
      options.y0,
      options.x1,
      options.y1,
      options.x2,
      options.y2,
      options.x3,
      options.y3
    );
  }
  /** Update the geometry when the texture is updated */
  textureUpdated() {
    const geometry = this.geometry;
    if (!geometry) return;
    const { width, height } = this.texture;
    if (geometry.width !== width || geometry.height !== height) {
      geometry.width = width;
      geometry.height = height;
      geometry.updateProjection();
    }
  }
  set texture(value) {
    if (this._texture === value) return;
    super.texture = value;
    this.textureUpdated();
  }
  /**
   * The texture that the mesh uses for rendering. When changed, automatically updates
   * the geometry to match the new texture dimensions.
   * @example
   * ```ts
   * const mesh = new PerspectiveMesh({
   *     texture: Texture.from('initial.png'),
   * });
   *
   * // Update texture and maintain perspective
   * mesh.texture = Texture.from('newImage.png');
   * ```
   * @see {@link Texture} For texture creation and management
   * @see {@link PerspectiveMesh#setCorners} For adjusting the mesh perspective
   */
  get texture() {
    return this._texture;
  }
  /**
   * Sets the corners of the mesh to create a perspective transformation. The corners should be
   * specified in clockwise order starting from the top-left.
   *
   * The mesh automatically recalculates the UV coordinates to create the perspective effect.
   * @example
   * ```ts
   * const mesh = new PerspectiveMesh({
   *     texture: Texture.from('myImage.png'),
   * });
   *
   * // Create a basic perspective tilt
   * mesh.setCorners(
   *     0, 0,      // Top-left
   *     100, 20,   // Top-right (raised)
   *     100, 100,  // Bottom-right
   *     0, 80      // Bottom-left
   * );
   *
   * // Create a skewed billboard effect
   * mesh.setCorners(
   *     0, 30,     // Top-left (shifted down)
   *     128, 0,    // Top-right (raised)
   *     128, 128,  // Bottom-right
   *     0, 98      // Bottom-left (shifted up)
   * );
   *
   * // Animate perspective
   * app.ticker.add((delta) => {
   *     const time = performance.now() / 1000;
   *     const wave = Math.sin(time) * 20;
   *
   *     mesh.setCorners(
   *         0, wave,      // Top-left
   *         100, -wave,   // Top-right
   *         100, 100,     // Bottom-right
   *         0, 100        // Bottom-left
   *     );
   * });
   * ```
   * @param x0 - x-coordinate of the top-left corner
   * @param y0 - y-coordinate of the top-left corner
   * @param x1 - x-coordinate of the top-right corner
   * @param y1 - y-coordinate of the top-right corner
   * @param x2 - x-coordinate of the bottom-right corner
   * @param y2 - y-coordinate of the bottom-right corner
   * @param x3 - x-coordinate of the bottom-left corner
   * @param y3 - y-coordinate of the bottom-left corner
   * @returns The PerspectiveMesh instance for method chaining
   * @see {@link PerspectivePlaneGeometry} For the underlying geometry calculations
   */
  setCorners(x0, y0, x1, y1, x2, y2, x3, y3) {
    this.geometry.setCorners(x0, y0, x1, y1, x2, y2, x3, y3);
  }
};
/**
 * Default options for creating a PerspectiveMesh instance.
 *
 * Creates a 100x100 pixel square mesh
 * with a white texture and 10x10 vertex grid for the perspective calculations.
 * @example
 * ```ts
 * // Change defaults globally
 * PerspectiveMesh.defaultOptions = {
 *     ...PerspectiveMesh.defaultOptions,
 *     verticesX: 15,
 *     verticesY: 15,
 *     // Move top edge up for default skew
 *     y0: -20,
 *     y1: -20
 * };
 * ```
 * @see {@link PerspectivePlaneOptions} For all available options
 * @see {@link PerspectivePlaneGeometry} For how vertices affect perspective quality
 */
_PerspectiveMesh.defaultOptions = {
  texture: Texture.WHITE,
  verticesX: 10,
  verticesY: 10,
  x0: 0,
  y0: 0,
  x1: 100,
  y1: 0,
  x2: 100,
  y2: 100,
  x3: 0,
  y3: 100
};
let PerspectiveMesh = _PerspectiveMesh;

export { PerspectiveMesh };
//# sourceMappingURL=PerspectiveMesh.mjs.map
