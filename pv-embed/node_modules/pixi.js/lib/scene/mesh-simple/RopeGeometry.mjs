import { MeshGeometry } from '../mesh/shared/MeshGeometry.mjs';

"use strict";
const _RopeGeometry = class _RopeGeometry extends MeshGeometry {
  /**
   * @param options - Options to be applied to rope geometry
   */
  constructor(options) {
    const { width, points, textureScale } = { ..._RopeGeometry.defaultOptions, ...options };
    super({
      positions: new Float32Array(points.length * 4),
      uvs: new Float32Array(points.length * 4),
      indices: new Uint32Array((points.length - 1) * 6)
    });
    this.points = points;
    this._width = width;
    this.textureScale = textureScale;
    this._build();
  }
  /**
   * The width (i.e., thickness) of the rope.
   * @readonly
   */
  get width() {
    return this._width;
  }
  /** Refreshes Rope indices and uvs */
  _build() {
    const points = this.points;
    if (!points) return;
    const vertexBuffer = this.getBuffer("aPosition");
    const uvBuffer = this.getBuffer("aUV");
    const indexBuffer = this.getIndex();
    if (points.length < 1) {
      return;
    }
    if (vertexBuffer.data.length / 4 !== points.length) {
      vertexBuffer.data = new Float32Array(points.length * 4);
      uvBuffer.data = new Float32Array(points.length * 4);
      indexBuffer.data = new Uint16Array((points.length - 1) * 6);
    }
    const uvs = uvBuffer.data;
    const indices = indexBuffer.data;
    uvs[0] = 0;
    uvs[1] = 0;
    uvs[2] = 0;
    uvs[3] = 1;
    let amount = 0;
    let prev = points[0];
    const textureWidth = this._width * this.textureScale;
    const total = points.length;
    for (let i = 0; i < total; i++) {
      const index = i * 4;
      if (this.textureScale > 0) {
        const dx = prev.x - points[i].x;
        const dy = prev.y - points[i].y;
        const distance = Math.sqrt(dx * dx + dy * dy);
        prev = points[i];
        amount += distance / textureWidth;
      } else {
        amount = i / (total - 1);
      }
      uvs[index] = amount;
      uvs[index + 1] = 0;
      uvs[index + 2] = amount;
      uvs[index + 3] = 1;
    }
    let indexCount = 0;
    for (let i = 0; i < total - 1; i++) {
      const index = i * 2;
      indices[indexCount++] = index;
      indices[indexCount++] = index + 1;
      indices[indexCount++] = index + 2;
      indices[indexCount++] = index + 2;
      indices[indexCount++] = index + 1;
      indices[indexCount++] = index + 3;
    }
    uvBuffer.update();
    indexBuffer.update();
    this.updateVertices();
  }
  /** refreshes vertices of Rope mesh */
  updateVertices() {
    const points = this.points;
    if (points.length < 1) {
      return;
    }
    let lastPoint = points[0];
    let nextPoint;
    let perpX = 0;
    let perpY = 0;
    const vertices = this.buffers[0].data;
    const total = points.length;
    const halfWidth = this.textureScale > 0 ? this.textureScale * this._width / 2 : this._width / 2;
    for (let i = 0; i < total; i++) {
      const point = points[i];
      const index = i * 4;
      if (i < points.length - 1) {
        nextPoint = points[i + 1];
      } else {
        nextPoint = point;
      }
      perpY = -(nextPoint.x - lastPoint.x);
      perpX = nextPoint.y - lastPoint.y;
      let ratio = (1 - i / (total - 1)) * 10;
      if (ratio > 1) {
        ratio = 1;
      }
      const perpLength = Math.sqrt(perpX * perpX + perpY * perpY);
      if (perpLength < 1e-6) {
        perpX = 0;
        perpY = 0;
      } else {
        perpX /= perpLength;
        perpY /= perpLength;
        perpX *= halfWidth;
        perpY *= halfWidth;
      }
      vertices[index] = point.x + perpX;
      vertices[index + 1] = point.y + perpY;
      vertices[index + 2] = point.x - perpX;
      vertices[index + 3] = point.y - perpY;
      lastPoint = point;
    }
    this.buffers[0].update();
  }
  /** Refreshes Rope indices and uvs */
  update() {
    if (this.textureScale > 0) {
      this._build();
    } else {
      this.updateVertices();
    }
  }
};
/** Default options for RopeGeometry constructor. */
_RopeGeometry.defaultOptions = {
  /** The width (i.e., thickness) of the rope. */
  width: 200,
  /** An array of points that determine the rope. */
  points: [],
  /** Rope texture scale, if zero then the rope texture is stretched. */
  textureScale: 0
};
let RopeGeometry = _RopeGeometry;

export { RopeGeometry };
//# sourceMappingURL=RopeGeometry.mjs.map
