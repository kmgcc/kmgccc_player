'use strict';

var utils = require('../../../../utils/utils.js');

"use strict";
function triangulateWithHoles(points, holes, vertices, verticesStride, verticesOffset, indices, indicesOffset) {
  const triangles = utils.earcut(points, holes, 2);
  if (!triangles) {
    return;
  }
  for (let i = 0; i < triangles.length; i += 3) {
    indices[indicesOffset++] = triangles[i] + verticesOffset;
    indices[indicesOffset++] = triangles[i + 1] + verticesOffset;
    indices[indicesOffset++] = triangles[i + 2] + verticesOffset;
  }
  let index = verticesOffset * verticesStride;
  for (let i = 0; i < points.length; i += 2) {
    vertices[index] = points[i];
    vertices[index + 1] = points[i + 1];
    index += verticesStride;
  }
}

exports.triangulateWithHoles = triangulateWithHoles;
//# sourceMappingURL=triangulateWithHoles.js.map
