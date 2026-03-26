import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { Batcher } from './Batcher.mjs';
import { BatchGeometry } from './BatchGeometry.mjs';
import { DefaultShader } from './DefaultShader.mjs';

"use strict";
let defaultShader = null;
const _DefaultBatcher = class _DefaultBatcher extends Batcher {
  constructor(options) {
    super(options);
    this.geometry = new BatchGeometry();
    this.name = _DefaultBatcher.extension.name;
    /** The size of one attribute. 1 = 32 bit. x, y, u, v, color, textureIdAndRound -> total = 6 */
    this.vertexSize = 6;
    defaultShader ?? (defaultShader = new DefaultShader(options.maxTextures));
    this.shader = defaultShader;
  }
  /**
   * Packs the attributes of a DefaultBatchableMeshElement into the provided views.
   * @param element - The DefaultBatchableMeshElement to pack.
   * @param float32View - The Float32Array view to pack into.
   * @param uint32View - The Uint32Array view to pack into.
   * @param index - The starting index in the views.
   * @param textureId - The texture ID to use.
   */
  packAttributes(element, float32View, uint32View, index, textureId) {
    const textureIdAndRound = textureId << 16 | element.roundPixels & 65535;
    const wt = element.transform;
    const a = wt.a;
    const b = wt.b;
    const c = wt.c;
    const d = wt.d;
    const tx = wt.tx;
    const ty = wt.ty;
    const { positions, uvs } = element;
    const argb = element.color;
    const offset = element.attributeOffset;
    const end = offset + element.attributeSize;
    for (let i = offset; i < end; i++) {
      const i2 = i * 2;
      const x = positions[i2];
      const y = positions[i2 + 1];
      float32View[index++] = a * x + c * y + tx;
      float32View[index++] = d * y + b * x + ty;
      float32View[index++] = uvs[i2];
      float32View[index++] = uvs[i2 + 1];
      uint32View[index++] = argb;
      uint32View[index++] = textureIdAndRound;
    }
  }
  /**
   * Packs the attributes of a DefaultBatchableQuadElement into the provided views.
   * @param element - The DefaultBatchableQuadElement to pack.
   * @param float32View - The Float32Array view to pack into.
   * @param uint32View - The Uint32Array view to pack into.
   * @param index - The starting index in the views.
   * @param textureId - The texture ID to use.
   */
  packQuadAttributes(element, float32View, uint32View, index, textureId) {
    const texture = element.texture;
    const wt = element.transform;
    const a = wt.a;
    const b = wt.b;
    const c = wt.c;
    const d = wt.d;
    const tx = wt.tx;
    const ty = wt.ty;
    const bounds = element.bounds;
    const w0 = bounds.maxX;
    const w1 = bounds.minX;
    const h0 = bounds.maxY;
    const h1 = bounds.minY;
    const uvs = texture.uvs;
    const argb = element.color;
    const textureIdAndRound = textureId << 16 | element.roundPixels & 65535;
    float32View[index + 0] = a * w1 + c * h1 + tx;
    float32View[index + 1] = d * h1 + b * w1 + ty;
    float32View[index + 2] = uvs.x0;
    float32View[index + 3] = uvs.y0;
    uint32View[index + 4] = argb;
    uint32View[index + 5] = textureIdAndRound;
    float32View[index + 6] = a * w0 + c * h1 + tx;
    float32View[index + 7] = d * h1 + b * w0 + ty;
    float32View[index + 8] = uvs.x1;
    float32View[index + 9] = uvs.y1;
    uint32View[index + 10] = argb;
    uint32View[index + 11] = textureIdAndRound;
    float32View[index + 12] = a * w0 + c * h0 + tx;
    float32View[index + 13] = d * h0 + b * w0 + ty;
    float32View[index + 14] = uvs.x2;
    float32View[index + 15] = uvs.y2;
    uint32View[index + 16] = argb;
    uint32View[index + 17] = textureIdAndRound;
    float32View[index + 18] = a * w1 + c * h0 + tx;
    float32View[index + 19] = d * h0 + b * w1 + ty;
    float32View[index + 20] = uvs.x3;
    float32View[index + 21] = uvs.y3;
    uint32View[index + 22] = argb;
    uint32View[index + 23] = textureIdAndRound;
  }
  /**
   * Updates the maximum number of textures that can be used in the shader.
   * @param maxTextures - The maximum number of textures that can be used in the shader.
   * @internal
   */
  _updateMaxTextures(maxTextures) {
    if (this.shader.maxTextures === maxTextures) return;
    defaultShader = new DefaultShader(maxTextures);
    this.shader = defaultShader;
  }
  destroy() {
    this.shader = null;
    super.destroy();
  }
};
/** @ignore */
_DefaultBatcher.extension = {
  type: [
    ExtensionType.Batcher
  ],
  name: "default"
};
let DefaultBatcher = _DefaultBatcher;

export { DefaultBatcher };
//# sourceMappingURL=DefaultBatcher.mjs.map
