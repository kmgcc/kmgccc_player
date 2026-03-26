import { definedProps } from '../container/utils/definedProps.mjs';
import { Mesh } from '../mesh/shared/Mesh.mjs';
import { PlaneGeometry } from './PlaneGeometry.mjs';

"use strict";
class MeshPlane extends Mesh {
  /**
   * @param options - Options to be applied to MeshPlane
   */
  constructor(options) {
    const { texture, verticesX, verticesY, ...rest } = options;
    const planeGeometry = new PlaneGeometry(definedProps({
      width: texture.width,
      height: texture.height,
      verticesX,
      verticesY
    }));
    super(definedProps({ ...rest, geometry: planeGeometry, texture }));
    this.texture = texture;
    this.autoResize = true;
  }
  /**
   * Method used for overrides, to do something in case texture frame was changed.
   * Meshes based on plane can override it and change more details based on texture.
   * @internal
   */
  textureUpdated() {
    const geometry = this.geometry;
    const { width, height } = this.texture;
    if (this.autoResize && (geometry.width !== width || geometry.height !== height)) {
      geometry.width = width;
      geometry.height = height;
      geometry.build({});
    }
  }
  set texture(value) {
    this._texture?.off("update", this.textureUpdated, this);
    super.texture = value;
    value.on("update", this.textureUpdated, this);
    this.textureUpdated();
  }
  /**
   * The texture that the mesh plane uses for rendering. When changed, automatically updates
   * geometry dimensions if autoResize is true and manages texture update event listeners.
   * @example
   * ```ts
   * const plane = new MeshPlane({
   *     texture: Assets.get('initial.png'),
   *     verticesX: 10,
   *     verticesY: 10
   * });
   *
   * // Update texture and auto-resize geometry
   * plane.texture = Assets.get('larger.png');
   * ```
   * @see {@link MeshPlane#autoResize} For controlling automatic geometry updates
   * @see {@link PlaneGeometry} For manual geometry updates
   * @see {@link Texture} For texture creation and management
   */
  get texture() {
    return this._texture;
  }
  /**
   * Destroys this sprite renderable and optionally its texture.
   * @param options - Options parameter. A boolean will act as if all options
   *  have been set to that value
   * @example
   * meshPlane.destroy();
   * meshPlane.destroy(true);
   * meshPlane.destroy({ texture: true, textureSource: true });
   */
  destroy(options) {
    this.texture.off("update", this.textureUpdated, this);
    super.destroy(options);
  }
}

export { MeshPlane };
//# sourceMappingURL=MeshPlane.mjs.map
