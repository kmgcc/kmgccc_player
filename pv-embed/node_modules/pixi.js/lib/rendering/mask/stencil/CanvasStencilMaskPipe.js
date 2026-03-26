'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var Graphics = require('../../../scene/graphics/shared/Graphics.js');
var warn = require('../../../utils/logging/warn.js');

"use strict";
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
      context.moveTo(circle.x + circle.radius, circle.y);
      context.arc(circle.x, circle.y, circle.radius, 0, Math.PI * 2);
      break;
    }
    case "ellipse": {
      const ellipse = shape;
      if (context.ellipse) {
        context.moveTo(ellipse.x + ellipse.halfWidth, ellipse.y);
        context.ellipse(ellipse.x, ellipse.y, ellipse.halfWidth, ellipse.halfHeight, 0, 0, Math.PI * 2);
      } else {
        context.save();
        context.translate(ellipse.x, ellipse.y);
        context.scale(ellipse.halfWidth, ellipse.halfHeight);
        context.moveTo(1, 0);
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
class CanvasStencilMaskPipe {
  constructor(renderer) {
    this._warnedMaskTypes = /* @__PURE__ */ new Set();
    this._canvasMaskStack = [];
    this._renderer = renderer;
  }
  push(mask, _container, instructionSet) {
    this._renderer.renderPipes.batch.break(instructionSet);
    instructionSet.add({
      renderPipeId: "stencilMask",
      action: "pushMaskBegin",
      mask,
      inverse: _container._maskOptions.inverse,
      canBundle: false
    });
  }
  pop(_mask, _container, instructionSet) {
    this._renderer.renderPipes.batch.break(instructionSet);
    instructionSet.add({
      renderPipeId: "stencilMask",
      action: "popMaskEnd",
      mask: _mask,
      inverse: _container._maskOptions.inverse,
      canBundle: false
    });
  }
  execute(instruction) {
    if (instruction.action !== "pushMaskBegin" && instruction.action !== "popMaskEnd") {
      return;
    }
    const canvasRenderer = this._renderer;
    const contextSystem = canvasRenderer.canvasContext;
    const context = contextSystem?.activeContext;
    if (!context) return;
    if (instruction.action === "popMaskEnd") {
      const didClip = this._canvasMaskStack.pop();
      if (didClip) {
        context.restore();
      }
      return;
    }
    if (instruction.inverse) {
      this._warnOnce(
        "inverse",
        "CanvasRenderer: inverse masks are not supported on Canvas2D; ignoring inverse flag."
      );
    }
    const maskContainer = instruction.mask.mask;
    if (!(maskContainer instanceof Graphics.Graphics)) {
      this._warnOnce(
        "nonGraphics",
        "CanvasRenderer: only Graphics masks are supported in Canvas2D; skipping mask."
      );
      this._canvasMaskStack.push(false);
      return;
    }
    const graphics = maskContainer;
    const instructions = graphics.context?.instructions;
    if (!instructions?.length) {
      this._canvasMaskStack.push(false);
      return;
    }
    context.save();
    contextSystem.setContextTransform(
      graphics.groupTransform,
      (canvasRenderer._roundPixels | graphics._roundPixels) === 1
    );
    context.beginPath();
    let drewPath = false;
    let hasHoles = false;
    for (let i = 0; i < instructions.length; i++) {
      const instructionData = instructions[i];
      const action = instructionData.action;
      if (action !== "fill" && action !== "stroke") continue;
      const data = instructionData.data;
      const shapePath = data?.path?.shapePath;
      if (!shapePath?.shapePrimitives?.length) continue;
      const shapePrimitives = shapePath.shapePrimitives;
      for (let j = 0; j < shapePrimitives.length; j++) {
        const primitive = shapePrimitives[j];
        if (!primitive?.shape) continue;
        const transform = primitive.transform;
        const hasTransform = transform && !transform.isIdentity();
        if (hasTransform) {
          context.save();
          context.transform(transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty);
        }
        buildShapePath(context, primitive.shape);
        hasHoles = addHolePaths(context, primitive.holes) || hasHoles;
        drewPath = true;
        if (hasTransform) {
          context.restore();
        }
      }
    }
    if (!drewPath) {
      context.restore();
      this._canvasMaskStack.push(false);
      return;
    }
    if (hasHoles) {
      context.clip("evenodd");
    } else {
      context.clip();
    }
    this._canvasMaskStack.push(true);
  }
  destroy() {
    this._renderer = null;
    this._warnedMaskTypes = null;
    this._canvasMaskStack = null;
  }
  _warnOnce(key, message) {
    if (this._warnedMaskTypes.has(key)) return;
    this._warnedMaskTypes.add(key);
    warn.warn(message);
  }
}
CanvasStencilMaskPipe.extension = {
  type: [
    Extensions.ExtensionType.CanvasPipes
  ],
  name: "stencilMask"
};

exports.CanvasStencilMaskPipe = CanvasStencilMaskPipe;
//# sourceMappingURL=CanvasStencilMaskPipe.js.map
