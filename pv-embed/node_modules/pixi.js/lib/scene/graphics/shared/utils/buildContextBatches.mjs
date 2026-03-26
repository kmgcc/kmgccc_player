import { extensions, ExtensionType } from '../../../../extensions/Extensions.mjs';
import { Matrix } from '../../../../maths/matrix/Matrix.mjs';
import { Rectangle } from '../../../../maths/shapes/Rectangle.mjs';
import { buildUvs, buildSimpleUvs } from '../../../../rendering/renderers/shared/geometry/utils/buildUvs.mjs';
import { transformVertices } from '../../../../rendering/renderers/shared/geometry/utils/transformVertices.mjs';
import { Texture } from '../../../../rendering/renderers/shared/texture/Texture.mjs';
import { BigPool } from '../../../../utils/pool/PoolGroup.mjs';
import { BatchableGraphics } from '../BatchableGraphics.mjs';
import { buildCircle, buildEllipse, buildRoundedRectangle } from '../buildCommands/buildCircle.mjs';
import { buildLine } from '../buildCommands/buildLine.mjs';
import { buildPixelLine } from '../buildCommands/buildPixelLine.mjs';
import { buildPolygon } from '../buildCommands/buildPolygon.mjs';
import { buildRectangle } from '../buildCommands/buildRectangle.mjs';
import { buildTriangle } from '../buildCommands/buildTriangle.mjs';
import { generateTextureMatrix } from './generateTextureFillMatrix.mjs';
import { triangulateWithHoles } from './triangulateWithHoles.mjs';

"use strict";
const shapeBuilders = {};
extensions.handleByMap(ExtensionType.ShapeBuilder, shapeBuilders);
extensions.add(buildRectangle, buildPolygon, buildTriangle, buildCircle, buildEllipse, buildRoundedRectangle);
const tempRect = new Rectangle();
const tempTextureMatrix = new Matrix();
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
    transformVertices(points, matrix);
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
  const graphicsBatch = BigPool.get(BatchableGraphics);
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
      transformVertices(points, matrix);
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
        triangulateWithHoles(otherPoints, holeIndices, vertices, 2, vertOffset, indices, indexOffset);
      } else {
        build.triangulate(points, vertices, 2, vertOffset, indices, indexOffset);
      }
    } else {
      const close = shape.closePath ?? true;
      const lineStyle = style;
      if (!lineStyle.pixelLine) {
        buildLine(points, lineStyle, false, close, vertices, indices);
      } else {
        buildPixelLine(points, close, vertices, indices);
        topology = "line-list";
      }
    }
    const uvsOffset = uvs.length / 2;
    const texture = style.texture;
    if (texture !== Texture.WHITE) {
      const textureMatrix = generateTextureMatrix(tempTextureMatrix, style, shape, matrix);
      buildUvs(vertices, 2, vertOffset, uvs, uvsOffset, 2, vertices.length / 2 - vertOffset, textureMatrix);
    } else {
      buildSimpleUvs(uvs, uvsOffset, 2, vertices.length / 2 - vertOffset);
    }
    const graphicsBatch = BigPool.get(BatchableGraphics);
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

export { buildContextBatches, shapeBuilders };
//# sourceMappingURL=buildContextBatches.mjs.map
