'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var groupD8 = require('../../../maths/matrix/groupD8.js');
var Matrix = require('../../../maths/matrix/Matrix.js');
var canvasUtils = require('../../../rendering/renderers/canvas/utils/canvasUtils.js');
var Texture = require('../../../rendering/renderers/shared/texture/Texture.js');
var getGlobalMixin = require('../../container/container-mixins/getGlobalMixin.js');
var multiplyHexColors = require('../../container/utils/multiplyHexColors.js');
var buildLine = require('../shared/buildCommands/buildLine.js');
var FillGradient = require('../shared/fill/FillGradient.js');
var FillPattern = require('../shared/fill/FillPattern.js');
var buildContextBatches = require('../shared/utils/buildContextBatches.js');
var generateTextureFillMatrix = require('../shared/utils/generateTextureFillMatrix.js');

"use strict";
const emptyCanvasStyle = "#808080";
const tempMatrix = new Matrix.Matrix();
const tempTextureMatrix = new Matrix.Matrix();
const tempGradientMatrix = new Matrix.Matrix();
const tempPatternMatrix = new Matrix.Matrix();
function fillTriangles(context, vertices, indices) {
  context.beginPath();
  for (let i = 0; i < indices.length; i += 3) {
    const i0 = indices[i] * 2;
    const i1 = indices[i + 1] * 2;
    const i2 = indices[i + 2] * 2;
    context.moveTo(vertices[i0], vertices[i0 + 1]);
    context.lineTo(vertices[i1], vertices[i1 + 1]);
    context.lineTo(vertices[i2], vertices[i2 + 1]);
    context.closePath();
  }
  context.fill();
}
function colorToHex(color) {
  const clamped = color & 16777215;
  return `#${clamped.toString(16).padStart(6, "0")}`;
}
function buildRoundedRectPath(context, x, y, width, height, radius) {
  radius = Math.max(0, Math.min(radius, Math.min(width, height) / 2));
  context.moveTo(x + radius, y);
  context.lineTo(x + width - radius, y);
  context.quadraticCurveTo(x + width, y, x + width, y + radius);
  context.lineTo(x + width, y + height - radius);
  context.quadraticCurveTo(x + width, y + height, x + width - radius, y + height);
  context.lineTo(x + radius, y + height);
  context.quadraticCurveTo(x, y + height, x, y + height - radius);
  context.lineTo(x, y + radius);
  context.quadraticCurveTo(x, y, x + radius, y);
}
function buildShapePath(context, shape) {
  switch (shape.type) {
    case "rectangle": {
      const rect = shape;
      context.rect(rect.x, rect.y, rect.width, rect.height);
      break;
    }
    case "roundedRectangle": {
      const rect = shape;
      buildRoundedRectPath(context, rect.x, rect.y, rect.width, rect.height, rect.radius);
      break;
    }
    case "circle": {
      const circle = shape;
      context.arc(circle.x, circle.y, circle.radius, 0, Math.PI * 2);
      break;
    }
    case "ellipse": {
      const ellipse = shape;
      if (context.ellipse) {
        context.ellipse(ellipse.x, ellipse.y, ellipse.halfWidth, ellipse.halfHeight, 0, 0, Math.PI * 2);
      } else {
        context.save();
        context.translate(ellipse.x, ellipse.y);
        context.scale(ellipse.halfWidth, ellipse.halfHeight);
        context.arc(0, 0, 1, 0, Math.PI * 2);
        context.restore();
      }
      break;
    }
    case "triangle": {
      const tri = shape;
      context.moveTo(tri.x, tri.y);
      context.lineTo(tri.x2, tri.y2);
      context.lineTo(tri.x3, tri.y3);
      context.closePath();
      break;
    }
    case "polygon":
    default: {
      const poly = shape;
      const points = poly.points;
      if (!points?.length) break;
      context.moveTo(points[0], points[1]);
      for (let i = 2; i < points.length; i += 2) {
        context.lineTo(points[i], points[i + 1]);
      }
      if (poly.closePath) {
        context.closePath();
      }
      break;
    }
  }
}
function addHolePaths(context, holes) {
  if (!holes?.length) return false;
  for (let i = 0; i < holes.length; i++) {
    const hole = holes[i];
    if (!hole?.shape) continue;
    const transform = hole.transform;
    const hasTransform = transform && !transform.isIdentity();
    if (hasTransform) {
      context.save();
      context.transform(transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty);
    }
    buildShapePath(context, hole.shape);
    if (hasTransform) {
      context.restore();
    }
  }
  return true;
}
function getCanvasStyle(style, tint, textureMatrix, currentTransform) {
  const fill = style.fill;
  if (fill instanceof FillGradient.FillGradient) {
    fill.buildGradient();
    const gradientTexture = fill.texture;
    if (gradientTexture) {
      const pattern = canvasUtils.canvasUtils.getTintedPattern(gradientTexture, tint);
      const patternMatrix = textureMatrix ? tempPatternMatrix.copyFrom(textureMatrix).scale(gradientTexture.source.pixelWidth, gradientTexture.source.pixelHeight) : tempPatternMatrix.copyFrom(fill.transform);
      if (currentTransform && !style.textureSpace) {
        patternMatrix.append(currentTransform);
      }
      canvasUtils.canvasUtils.applyPatternTransform(pattern, patternMatrix);
      return pattern;
    }
  }
  if (fill instanceof FillPattern.FillPattern) {
    const pattern = canvasUtils.canvasUtils.getTintedPattern(fill.texture, tint);
    canvasUtils.canvasUtils.applyPatternTransform(pattern, fill.transform);
    return pattern;
  }
  const texture = style.texture;
  if (texture && texture !== Texture.Texture.WHITE) {
    if (!texture.source.resource) {
      return emptyCanvasStyle;
    }
    const pattern = canvasUtils.canvasUtils.getTintedPattern(texture, tint);
    const patternMatrix = textureMatrix ? tempPatternMatrix.copyFrom(textureMatrix).scale(texture.source.pixelWidth, texture.source.pixelHeight) : style.matrix;
    canvasUtils.canvasUtils.applyPatternTransform(pattern, patternMatrix);
    return pattern;
  }
  return colorToHex(tint);
}
class CanvasGraphicsAdaptor {
  constructor() {
    this.shader = null;
  }
  contextChange(renderer) {
    void renderer;
  }
  execute(graphicsPipe, renderable) {
    const renderer = graphicsPipe.renderer;
    const contextSystem = renderer.canvasContext;
    const context = contextSystem.activeContext;
    const baseTransform = renderable.groupTransform;
    const globalColor = renderer.globalUniforms.globalUniformData?.worldColor ?? 4294967295;
    const groupColorAlpha = renderable.groupColorAlpha;
    const globalAlpha = (globalColor >>> 24 & 255) / 255;
    const groupAlphaValue = (groupColorAlpha >>> 24 & 255) / 255;
    const filterAlpha = renderer.filter?.alphaMultiplier ?? 1;
    const groupAlpha = globalAlpha * groupAlphaValue * filterAlpha;
    if (groupAlpha <= 0) return;
    const globalTint = globalColor & 16777215;
    const groupTintBGR = groupColorAlpha & 16777215;
    const groupTint = getGlobalMixin.bgr2rgb(multiplyHexColors.multiplyHexColors(groupTintBGR, globalTint));
    const roundPixels = renderer._roundPixels | renderable._roundPixels;
    context.save();
    contextSystem.setContextTransform(baseTransform, roundPixels === 1);
    contextSystem.setBlendMode(renderable.groupBlendMode);
    const instructions = renderable.context.instructions;
    for (let i = 0; i < instructions.length; i++) {
      const instruction = instructions[i];
      if (instruction.action === "texture") {
        const data2 = instruction.data;
        const texture = data2.image;
        const source = texture ? canvasUtils.canvasUtils.getCanvasSource(texture) : null;
        if (!source) continue;
        const alpha2 = data2.alpha * groupAlpha;
        if (alpha2 <= 0) continue;
        const tint2 = multiplyHexColors.multiplyHexColors(data2.style, groupTint);
        context.globalAlpha = alpha2;
        let drawSource = source;
        if (tint2 !== 16777215) {
          drawSource = canvasUtils.canvasUtils.getTintedCanvas({ texture }, tint2);
        }
        const frame = texture.frame;
        const resolution = texture.source._resolution ?? texture.source.resolution ?? 1;
        let sx = frame.x * resolution;
        let sy = frame.y * resolution;
        const sw = frame.width * resolution;
        const sh = frame.height * resolution;
        if (drawSource !== source) {
          sx = 0;
          sy = 0;
        }
        const transform = data2.transform;
        const hasTransform = transform && !transform.isIdentity();
        const rotate = texture.rotate;
        if (hasTransform || rotate) {
          tempMatrix.copyFrom(baseTransform);
          if (hasTransform) {
            tempMatrix.append(transform);
          }
          if (rotate) {
            groupD8.groupD8.matrixAppendRotationInv(tempMatrix, rotate, data2.dx, data2.dy, data2.dw, data2.dh);
          }
          contextSystem.setContextTransform(tempMatrix, roundPixels === 1);
        } else {
          contextSystem.setContextTransform(baseTransform, roundPixels === 1);
        }
        context.drawImage(
          drawSource,
          sx,
          sy,
          drawSource === source ? sw : drawSource.width,
          drawSource === source ? sh : drawSource.height,
          rotate ? 0 : data2.dx,
          rotate ? 0 : data2.dy,
          data2.dw,
          data2.dh
        );
        if (hasTransform || rotate) {
          contextSystem.setContextTransform(baseTransform, roundPixels === 1);
        }
        continue;
      }
      const data = instruction.data;
      const shapePath = data?.path?.shapePath;
      if (!shapePath?.shapePrimitives?.length) continue;
      const style = data.style;
      const tint = multiplyHexColors.multiplyHexColors(style.color, groupTint);
      const alpha = style.alpha * groupAlpha;
      if (alpha <= 0) continue;
      const isStroke = instruction.action === "stroke";
      context.globalAlpha = alpha;
      if (isStroke) {
        const strokeStyle = style;
        context.lineWidth = strokeStyle.width;
        context.lineCap = strokeStyle.cap;
        context.lineJoin = strokeStyle.join;
        context.miterLimit = strokeStyle.miterLimit;
      }
      const shapePrimitives = shapePath.shapePrimitives;
      if (!isStroke && data.hole?.shapePath?.shapePrimitives?.length) {
        const lastShape = shapePrimitives[shapePrimitives.length - 1];
        lastShape.holes = data.hole.shapePath.shapePrimitives;
      }
      for (let j = 0; j < shapePrimitives.length; j++) {
        const primitive = shapePrimitives[j];
        if (!primitive?.shape) continue;
        const transform = primitive.transform;
        const hasTransform = transform && !transform.isIdentity();
        const hasTexture = style.texture && style.texture !== Texture.Texture.WHITE;
        const textureTransform = style.textureSpace === "global" ? transform : null;
        const textureMatrix = hasTexture ? generateTextureFillMatrix.generateTextureMatrix(tempTextureMatrix, style, primitive.shape, textureTransform) : null;
        const currentTransform = hasTransform ? tempGradientMatrix.copyFrom(baseTransform).append(transform) : baseTransform;
        const canvasStyle = getCanvasStyle(
          style,
          tint,
          textureMatrix,
          currentTransform
        );
        if (hasTransform) {
          context.save();
          context.transform(transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty);
        }
        if (isStroke) {
          const strokeStyle = style;
          const useStrokeGeometry = strokeStyle.alignment !== 0.5 && !strokeStyle.pixelLine;
          if (useStrokeGeometry) {
            const points = [];
            const vertices = [];
            const indices = [];
            const shapeBuilder = buildContextBatches.shapeBuilders[primitive.shape.type];
            if (shapeBuilder?.build(primitive.shape, points)) {
              const close = primitive.shape.closePath ?? true;
              buildLine.buildLine(points, strokeStyle, false, close, vertices, indices);
              context.fillStyle = canvasStyle;
              fillTriangles(context, vertices, indices);
            } else {
              context.strokeStyle = canvasStyle;
              context.beginPath();
              buildShapePath(context, primitive.shape);
              context.stroke();
            }
          } else {
            context.strokeStyle = canvasStyle;
            context.beginPath();
            buildShapePath(context, primitive.shape);
            context.stroke();
          }
        } else {
          context.fillStyle = canvasStyle;
          context.beginPath();
          buildShapePath(context, primitive.shape);
          const hasHoles = addHolePaths(context, primitive.holes);
          if (hasHoles) {
            context.fill("evenodd");
          } else {
            context.fill();
          }
        }
        if (hasTransform) {
          context.restore();
        }
      }
    }
    context.restore();
  }
  destroy() {
    this.shader = null;
  }
}
/** @ignore */
CanvasGraphicsAdaptor.extension = {
  type: [
    Extensions.ExtensionType.CanvasPipesAdaptor
  ],
  name: "graphics"
};

exports.CanvasGraphicsAdaptor = CanvasGraphicsAdaptor;
//# sourceMappingURL=CanvasGraphicsAdaptor.js.map
