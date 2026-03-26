'use strict';

var Extensions = require('../../../../extensions/Extensions.js');

"use strict";
const buildTriangle = {
  extension: {
    type: Extensions.ExtensionType.ShapeBuilder,
    name: "triangle"
  },
  build(shape, points) {
    points[0] = shape.x;
    points[1] = shape.y;
    points[2] = shape.x2;
    points[3] = shape.y2;
    points[4] = shape.x3;
    points[5] = shape.y3;
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
    vertices[verticesOffset + count] = points[4];
    vertices[verticesOffset + count + 1] = points[5];
    const verticesIndex = verticesOffset / verticesStride;
    indices[indicesOffset++] = verticesIndex;
    indices[indicesOffset++] = verticesIndex + 1;
    indices[indicesOffset++] = verticesIndex + 2;
  }
};

exports.buildTriangle = buildTriangle;
//# sourceMappingURL=buildTriangle.js.map
