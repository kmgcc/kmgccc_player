import { definedProps } from '../container/utils/definedProps.mjs';
import { Mesh } from '../mesh/shared/Mesh.mjs';
import { MeshGeometry } from '../mesh/shared/MeshGeometry.mjs';

"use strict";
class MeshSimple extends Mesh {
  /**
   * @param options - Options to be used for construction
   */
  constructor(options) {
    const { texture, vertices, uvs, indices, topology, ...rest } = options;
    const geometry = new MeshGeometry(definedProps({
      positions: vertices,
      uvs,
      indices,
      topology
    }));
    super(definedProps({
      ...rest,
      texture,
      geometry
    }));
    this.autoUpdate = true;
    this.onRender = this._render;
  }
  /**
   * The vertex positions of the mesh as a TypedArray. Each vertex is represented by two
   * consecutive values (x, y) in the array. Changes to these values will update the mesh's shape.
   * @example
   * ```ts
   * // Read vertex positions
   * const vertices = mesh.vertices;
   * console.log('First vertex:', vertices[0], vertices[1]);
   *
   * // Modify vertices directly
   * vertices[0] += 10;  // Move first vertex right
   * vertices[1] -= 20;  // Move first vertex up
   *
   * // Animate vertices
   * app.ticker.add(() => {
   *     const time = performance.now() / 1000;
   *     const vertices = mesh.vertices;
   *
   *     // Wave motion
   *     for (let i = 0; i < vertices.length; i += 2) {
   *         vertices[i + 1] = Math.sin(time + i * 0.5) * 20;
   *     }
   * });
   * ```
   * @see {@link MeshSimple#autoUpdate} For controlling vertex buffer updates
   * @see {@link MeshGeometry#getBuffer} For direct buffer access
   */
  get vertices() {
    return this.geometry.getBuffer("aPosition").data;
  }
  set vertices(value) {
    this.geometry.getBuffer("aPosition").data = value;
  }
  _render() {
    if (this.autoUpdate) {
      this.geometry.getBuffer("aPosition").update();
    }
  }
}

export { MeshSimple };
//# sourceMappingURL=MeshSimple.mjs.map
