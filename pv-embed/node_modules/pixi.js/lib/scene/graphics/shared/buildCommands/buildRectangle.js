'use strict';

var Extensions = require('../../../../extensions/Extensions.js');

"use strict";
const buildRectangle = {
  extension: {
    type: Extensions.ExtensionType.ShapeBuilder,
    name: "rectangle"
  },
  build(shape, points) {
    const rectData = shape;
    const x = rectData.x;
    const y = rectData.y;
    const width = rectData.width;
    const height = rectData.height;
    if (!(width > 0 && height > 0)) {
      return false;
    }
    points[0] = x;
    points[1] = y;
    points[2] = x + width;
    points[3] = y;
    points[4] = x + width;
    points[5] = y + height;
    points[6] = x;
    points[7] = y + height;
    return true;
  },
  triangulate(points, vertices, verticesStride, verticesOffset, indices, indicesOffset) {
    let count = 0;
    verticesOffset *= verticesStride;
    vertices[verticesOffset + count] = points[0];
    vertices[verticesOffset + count + 1] = points[1];
    count += verticesStride;
    vertices[verticesOffset + count] = points[2];
    vertices[verticesOffset + count + 1] = points[3];
    count += verticesStride;
    vertices[verticesOffset + count] = points[6];
    vertices[verticesOffset + count + 1] = points[7];
    count += verticesStride;
    vertices[verticesOffset + count] = points[4];
    vertices[verticesOffset + count + 1] = points[5];
    count += verticesStride;
    const verticesIndex = verticesOffset / verticesStride;
    indices[indicesOffset++] = verticesIndex;
    indices[indicesOffset++] = verticesIndex + 1;
    indices[indicesOffset++] = verticesIndex + 2;
    indices[indicesOffset++] = verticesIndex + 1;
    indices[indicesOffset++] = verticesIndex + 3;
    indices[indicesOffset++] = verticesIndex + 2;
  }
};

exports.buildRectangle = buildRectangle;
//# sourceMappingURL=buildRectangle.js.map
