'use strict';

var Extensions = require('../../../../extensions/Extensions.js');
var triangulateWithHoles = require('../utils/triangulateWithHoles.js');

"use strict";
const emptyArray = [];
const buildPolygon = {
  extension: {
    type: Extensions.ExtensionType.ShapeBuilder,
    name: "polygon"
  },
  build(shape, points) {
    for (let i = 0; i < shape.points.length; i++) {
      points[i] = shape.points[i];
    }
    return true;
  },
  triangulate(points, vertices, verticesStride, verticesOffset, indices, indicesOffset) {
    triangulateWithHoles.triangulateWithHoles(points, emptyArray, vertices, verticesStride, verticesOffset, indices, indicesOffset);
  }
};

exports.buildPolygon = buildPolygon;
//# sourceMappingURL=buildPolygon.js.map
