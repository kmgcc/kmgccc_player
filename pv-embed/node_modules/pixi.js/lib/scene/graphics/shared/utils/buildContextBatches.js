'use strict';

var Extensions = require('../../../../extensions/Extensions.js');
var Matrix = require('../../../../maths/matrix/Matrix.js');
var Rectangle = require('../../../../maths/shapes/Rectangle.js');
var buildUvs = require('../../../../rendering/renderers/shared/geometry/utils/buildUvs.js');
var transformVertices = require('../../../../rendering/renderers/shared/geometry/utils/transformVertices.js');
var Texture = require('../../../../rendering/renderers/shared/texture/Texture.js');
var PoolGroup = require('../../../../utils/pool/PoolGroup.js');
var BatchableGraphics = require('../BatchableGraphics.js');
var buildCircle = require('../buildCommands/buildCircle.js');
var buildLine = require('../buildCommands/buildLine.js');
var buildPixelLine = require('../buildCommands/buildPixelLine.js');
var buildPolygon = require('../buildCommands/buildPolygon.js');
var buildRectangle = require('../buildCommands/buildRectangle.js');
var buildTriangle = require('../buildCommands/buildTriangle.js');
var generateTextureFillMatrix = require('./generateTextureFillMatrix.js');
var triangulateWithHoles = require('./triangulateWithHoles.js');

"use strict";
const shapeBuilders = {};
Extensions.extensions.handleByMap(Extensions.ExtensionType.ShapeBuilder, shapeBuilders);
Extensions.extensions.add(buildRectangle.buildRectangle, buildPolygon.buildPolygon, buildTriangle.buildTriangle, buildCircle.buildCircle, buildCircle.buildEllipse, buildCircle.buildRoundedRectangle);
const tempRect = new Rectangle.Rectangle();
const tempTextureMatrix = new Matrix.Matrix();
function buildContextBatches(context, gpuContext) {
  const { geometryData, batches } = gpuContext;
  batches.length = 0;
  geometryData.indices.length = 0;
  geometryData.vertices.length = 0;
  geometryData.uvs.length = 0;
  for (let i = 0; i < context.instructions.length; i++) {
    const instruction = context.instructions[i];
    if (instruction.action === "texture") {
      addTextureToGeometryData(instruction.data, batches, geometryData);
    } else if (instruction.action === "fill" || instruction.action === "stroke") {
      const isStroke = instruction.action === "stroke";
      const shapePath = instruction.data.path.shapePath;
      const style = instruction.data.style;
      const hole = instruction.data.hole;
      if (isStroke && hole) {
        addShapePathToGeometryData(hole.shapePath, style, true, batches, geometryData);
      }
      if (hole) {
        shapePath.shapePrimitives[shapePath.shapePrimitives.length - 1].holes = hole.shapePath.shapePrimitives;
      }
      addShapePathToGeometryData(shapePath, style, isStroke, batches, geometryData);
    }
  }
}
function addTextureToGeometryData(data, batches, geometryData) {
  const points = [];
  const build = shapeBuilders.rectangle;
  const rect = tempRect;
  rect.x = data.dx;
  rect.y = data.dy;
  rect.width = data.dw;
  rect.height = data.dh;
  const matrix = data.transform;
  if (!build.build(rect, points)) {
    return;
  }
  const { vertices, uvs, indices } = geometryData;
  const indexOffset = indices.length;
  const vertOffset = vertices.length / 2;
  if (matrix) {
    transformVertices.transformVertices(points, matrix);
  }
  build.triangulate(points, vertices, 2, vertOffset, indices, indexOffset);
  const texture = data.image;
  const textureUvs = texture.uvs;
  uvs.push(
    textureUvs.x0,
    textureUvs.y0,
    textureUvs.x1,
    textureUvs.y1,
    textureUvs.x3,
    textureUvs.y3,
    textureUvs.x2,
    textureUvs.y2
  );
  const graphicsBatch = PoolGroup.BigPool.get(BatchableGraphics.BatchableGraphics);
  graphicsBatch.indexOffset = indexOffset;
  graphicsBatch.indexSize = indices.length - indexOffset;
  graphicsBatch.attributeOffset = vertOffset;
  graphicsBatch.attributeSize = vertices.length / 2 - vertOffset;
  graphicsBatch.baseColor = data.style;
  graphicsBatch.alpha = data.alpha;
  graphicsBatch.texture = texture;
  graphicsBatch.geometryData = geometryData;
  batches.push(graphicsBatch);
}
function addShapePathToGeometryData(shapePath, style, isStroke, batches, geometryData) {
  const { vertices, uvs, indices } = geometryData;
  shapePath.shapePrimitives.forEach(({ shape, transform: matrix, holes }) => {
    const points = [];
    const build = shapeBuilders[shape.type];
    if (!build.build(shape, points)) {
      return;
    }
    const indexOffset = indices.length;
    const vertOffset = vertices.length / 2;
    let topology = "triangle-list";
    if (matrix) {
      transformVertices.transformVertices(points, matrix);
    }
    if (!isStroke) {
      if (holes) {
        const holeIndices = [];
        const otherPoints = points.slice();
        const holeArrays = getHoleArrays(holes);
        holeArrays.forEach((holePoints) => {
          holeIndices.push(otherPoints.length / 2);
          otherPoints.push(...holePoints);
        });
        triangulateWithHoles.triangulateWithHoles(otherPoints, holeIndices, vertices, 2, vertOffset, indices, indexOffset);
      } else {
        build.triangulate(points, vertices, 2, vertOffset, indices, indexOffset);
      }
    } else {
      const close = shape.closePath ?? true;
      const lineStyle = style;
      if (!lineStyle.pixelLine) {
        buildLine.buildLine(points, lineStyle, false, close, vertices, indices);
      } else {
        buildPixelLine.buildPixelLine(points, close, vertices, indices);
        topology = "line-list";
      }
    }
    const uvsOffset = uvs.length / 2;
    const texture = style.texture;
    if (texture !== Texture.Texture.WHITE) {
      const textureMatrix = generateTextureFillMatrix.generateTextureMatrix(tempTextureMatrix, style, shape, matrix);
      buildUvs.buildUvs(vertices, 2, vertOffset, uvs, uvsOffset, 2, vertices.length / 2 - vertOffset, textureMatrix);
    } else {
      buildUvs.buildSimpleUvs(uvs, uvsOffset, 2, vertices.length / 2 - vertOffset);
    }
    const graphicsBatch = PoolGroup.BigPool.get(BatchableGraphics.BatchableGraphics);
    graphicsBatch.indexOffset = indexOffset;
    graphicsBatch.indexSize = indices.length - indexOffset;
    graphicsBatch.attributeOffset = vertOffset;
    graphicsBatch.attributeSize = vertices.length / 2 - vertOffset;
    graphicsBatch.baseColor = style.color;
    graphicsBatch.alpha = style.alpha;
    graphicsBatch.texture = texture;
    graphicsBatch.geometryData = geometryData;
    graphicsBatch.topology = topology;
    batches.push(graphicsBatch);
  });
}
function getHoleArrays(holePrimitives) {
  const holeArrays = [];
  for (let k = 0; k < holePrimitives.length; k++) {
    const holePrimitive = holePrimitives[k].shape;
    const holePoints = [];
    const holeBuilder = shapeBuilders[holePrimitive.type];
    if (holeBuilder.build(holePrimitive, holePoints)) {
      holeArrays.push(holePoints);
    }
  }
  return holeArrays;
}

exports.buildContextBatches = buildContextBatches;
exports.shapeBuilders = shapeBuilders;
//# sourceMappingURL=buildContextBatches.js.map
