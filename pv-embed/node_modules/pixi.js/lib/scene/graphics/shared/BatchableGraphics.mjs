import { Matrix } from '../../../maths/matrix/Matrix.mjs';
import { multiplyHexColors } from '../../container/utils/multiplyHexColors.mjs';

"use strict";
const identityMatrix = new Matrix();
class BatchableGraphics {
  constructor() {
    this.packAsQuad = false;
    this.batcherName = "default";
    this.topology = "triangle-list";
    this.applyTransform = true;
    this.roundPixels = 0;
    this._batcher = null;
    this._batch = null;
  }
  get uvs() {
    return this.geometryData.uvs;
  }
  get positions() {
    return this.geometryData.vertices;
  }
  get indices() {
    return this.geometryData.indices;
  }
  get blendMode() {
    if (this.renderable && this.applyTransform) {
      return this.renderable.groupBlendMode;
    }
    return "normal";
  }
  get color() {
    const rgb = this.baseColor;
    const bgr = rgb >> 16 | rgb & 65280 | (rgb & 255) << 16;
    const renderable = this.renderable;
    if (renderable) {
      return multiplyHexColors(bgr, renderable.groupColor) + (this.alpha * renderable.groupAlpha * 255 << 24);
    }
    return bgr + (this.alpha * 255 << 24);
  }
  get transform() {
    return this.renderable?.groupTransform || identityMatrix;
  }
  copyTo(gpuBuffer) {
    gpuBuffer.indexOffset = this.indexOffset;
    gpuBuffer.indexSize = this.indexSize;
    gpuBuffer.attributeOffset = this.attributeOffset;
    gpuBuffer.attributeSize = this.attributeSize;
    gpuBuffer.baseColor = this.baseColor;
    gpuBuffer.alpha = this.alpha;
    gpuBuffer.texture = this.texture;
    gpuBuffer.geometryData = this.geometryData;
    gpuBuffer.topology = this.topology;
  }
  reset() {
    this.applyTransform = true;
    this.renderable = null;
    this.topology = "triangle-list";
  }
  destroy() {
    this.renderable = null;
    this.texture = null;
    this.geometryData = null;
    this._batcher = null;
    this._batch = null;
  }
}

export { BatchableGraphics };
//# sourceMappingURL=BatchableGraphics.mjs.map
