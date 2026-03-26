import { ExtensionType } from '../../../../extensions/Extensions.mjs';
import { triangulateWithHoles } from '../utils/triangulateWithHoles.mjs';

"use strict";
const emptyArray = [];
const buildPolygon = {
  extension: {
    type: ExtensionType.ShapeBuilder,
    name: "polygon"
  },
  build(shape, points) {
    for (let i = 0; i < shape.points.length; i++) {
      points[i] = shape.points[i];
    }
    return true;
  },
  triangulate(points, vertices, verticesStride, verticesOffset, indices, indicesOffset) {
    triangulateWithHoles(points, emptyArray, vertices, verticesStride, verticesOffset, indices, indicesOffset);
  }
};

export { buildPolygon };
//# sourceMappingURL=buildPolygon.mjs.map
