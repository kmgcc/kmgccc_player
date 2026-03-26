'use strict';

var Color = require('../../../../color/Color.js');
var Matrix = require('../../../../maths/matrix/Matrix.js');
var Texture = require('../../../../rendering/renderers/shared/texture/Texture.js');
var warn = require('../../../../utils/logging/warn.js');
var FillGradient = require('../../../graphics/shared/fill/FillGradient.js');
var FillPattern = require('../../../graphics/shared/fill/FillPattern.js');

"use strict";
const PRECISION = 1e5;
function getCanvasFillStyle(fillStyle, context, textMetrics, padding = 0, offsetX = 0, offsetY = 0) {
  if (fillStyle.texture === Texture.Texture.WHITE && !fillStyle.fill) {
    return Color.Color.shared.setValue(fillStyle.color).setAlpha(fillStyle.alpha ?? 1).toHexa();
  } else if (!fillStyle.fill) {
    const pattern = context.createPattern(fillStyle.texture.source.resource, "repeat");
    const tempMatrix = fillStyle.matrix.copyTo(Matrix.Matrix.shared);
    tempMatrix.scale(fillStyle.texture.source.pixelWidth, fillStyle.texture.source.pixelHeight);
    pattern.setTransform(tempMatrix);
    return pattern;
  } else if (fillStyle.fill instanceof FillPattern.FillPattern) {
    const fillPattern = fillStyle.fill;
    const pattern = context.createPattern(fillPattern.texture.source.resource, "repeat");
    const tempMatrix = fillPattern.transform.copyTo(Matrix.Matrix.shared);
    tempMatrix.scale(
      fillPattern.texture.source.pixelWidth,
      fillPattern.texture.source.pixelHeight
    );
    pattern.setTransform(tempMatrix);
    return pattern;
  } else if (fillStyle.fill instanceof FillGradient.FillGradient) {
    const fillGradient = fillStyle.fill;
    const isLinear = fillGradient.type === "linear";
    const isLocal = fillGradient.textureSpace === "local";
    let width = 1;
    let height = 1;
    if (isLocal && textMetrics) {
      width = textMetrics.width + padding;
      height = textMetrics.height + padding;
    }
    let gradient;
    let isNearlyVertical = false;
    if (isLinear) {
      const { start, end } = fillGradient;
      gradient = context.createLinearGradient(
        start.x * width + offsetX,
        start.y * height + offsetY,
        end.x * width + offsetX,
        end.y * height + offsetY
      );
      isNearlyVertical = Math.abs(end.x - start.x) < Math.abs((end.y - start.y) * 0.1);
    } else {
      const { center, innerRadius, outerCenter, outerRadius } = fillGradient;
      gradient = context.createRadialGradient(
        center.x * width + offsetX,
        center.y * height + offsetY,
        innerRadius * width,
        outerCenter.x * width + offsetX,
        outerCenter.y * height + offsetY,
        outerRadius * width
      );
    }
    if (isNearlyVertical && isLocal && textMetrics) {
      const ratio = textMetrics.lineHeight / height;
      for (let i = 0; i < textMetrics.lines.length; i++) {
        const start = (i * textMetrics.lineHeight + padding / 2) / height;
        fillGradient.colorStops.forEach((stop) => {
          let globalStop = start + stop.offset * ratio;
          globalStop = Math.max(0, Math.min(1, globalStop));
          gradient.addColorStop(
            // fix to 5 decimal places to avoid floating point precision issues
            Math.floor(globalStop * PRECISION) / PRECISION,
            Color.Color.shared.setValue(stop.color).toHex()
          );
        });
      }
    } else {
      fillGradient.colorStops.forEach((stop) => {
        gradient.addColorStop(stop.offset, Color.Color.shared.setValue(stop.color).toHex());
      });
    }
    return gradient;
  }
  warn.warn("FillStyle not recognised", fillStyle);
  return "red";
}

exports.getCanvasFillStyle = getCanvasFillStyle;
//# sourceMappingURL=getCanvasFillStyle.js.map
