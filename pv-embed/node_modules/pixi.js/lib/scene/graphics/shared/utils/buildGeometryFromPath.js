'use strict';

var buildUvs = require('../../../../rendering/renderers/shared/geometry/utils/buildUvs.js');
var transformVertices = require('../../../../rendering/renderers/shared/geometry/utils/transformVertices.js');
var MeshGeometry = require('../../../mesh/shared/MeshGeometry.js');
var GraphicsPath = require('../path/GraphicsPath.js');
var buildContextBatches = require('./buildContextBatches.js');

"use strict";
function buildGeometryFromPath(options) {
  if (options instanceof GraphicsPath.GraphicsPath) {
    options = {
      path: options,
      textureMatrix: null,
      out: null
    };
  }
  const vertices = [];
  const uvs = [];
  const indices = [];
  const shapePath = options.path.shapePath;
  const textureMatrix = options.textureMatrix;
  shapePath.shapePrimitives.forEach(({ shape, transform: matrix }) => {
    const indexOffset = indices.length;
    const vertOffset = vertices.length / 2;
    const points = [];
    const build = buildContextBatches.shapeBuilders[shape.type];
    build.build(shape, points);
    if (matrix) {
      transformVertices.transformVertices(points, matrix);
    }
    build.triangulate(points, vertices, 2, vertOffset, indices, indexOffset);
    const uvsOffset = uvs.length / 2;
    if (textureMatrix) {
      if (matrix) {
        textureMatrix.append(matrix.clone().invert());
      }
      buildUvs.buildUvs(vertices, 2, vertOffset, uvs, uvsOffset, 2, vertices.length / 2 - vertOffset, textureMatrix);
    } else {
      buildUvs.buildSimpleUvs(uvs, uvsOffset, 2, vertices.length / 2 - vertOffset);
    }
  });
  const out = options.out;
  if (out) {
    out.positions = new Float32Array(vertices);
    out.uvs = new Float32Array(uvs);
    out.indices = new Uint32Array(indices);
    return out;
  }
  const geometry = new MeshGeometry.MeshGeometry({
    positions: new Float32Array(vertices),
    uvs: new Float32Array(uvs),
    indices: new Uint32Array(indices)
  });
  return geometry;
}

exports.buildGeometryFromPath = buildGeometryFromPath;
//# sourceMappingURL=buildGeometryFromPath.js.map
