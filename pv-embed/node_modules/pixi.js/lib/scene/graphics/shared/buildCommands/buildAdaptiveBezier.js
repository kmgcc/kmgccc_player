'use strict';

var GraphicsContextSystem = require('../GraphicsContextSystem.js');

"use strict";
const RECURSION_LIMIT = 8;
const FLT_EPSILON = 11920929e-14;
const PATH_DISTANCE_EPSILON = 1;
const curveAngleToleranceEpsilon = 0.01;
const mAngleTolerance = 0;
const mCuspLimit = 0;
function buildAdaptiveBezier(points, sX, sY, cp1x, cp1y, cp2x, cp2y, eX, eY, smoothness) {
  const scale = 1;
  const smoothing = Math.min(
    0.99,
    // a value of 1.0 actually inverts smoothing, so we cap it at 0.99
    Math.max(0, smoothness ?? GraphicsContextSystem.GraphicsContextSystem.defaultOptions.bezierSmoothness)
  );
  let distanceTolerance = (PATH_DISTANCE_EPSILON - smoothing) / scale;
  distanceTolerance *= distanceTolerance;
  begin(sX, sY, cp1x, cp1y, cp2x, cp2y, eX, eY, points, distanceTolerance);
  return points;
}
function begin(sX, sY, cp1x, cp1y, cp2x, cp2y, eX, eY, points, distanceTolerance) {
  recursive(sX, sY, cp1x, cp1y, cp2x, cp2y, eX, eY, points, distanceTolerance, 0);
  points.push(eX, eY);
}
function recursive(x1, y1, x2, y2, x3, y3, x4, y4, points, distanceTolerance, level) {
  if (level > RECURSION_LIMIT) {
    return;
  }
  const pi = Math.PI;
  const x12 = (x1 + x2) / 2;
  const y12 = (y1 + y2) / 2;
  const x23 = (x2 + x3) / 2;
  const y23 = (y2 + y3) / 2;
  const x34 = (x3 + x4) / 2;
  const y34 = (y3 + y4) / 2;
  const x123 = (x12 + x23) / 2;
  const y123 = (y12 + y23) / 2;
  const x234 = (x23 + x34) / 2;
  const y234 = (y23 + y34) / 2;
  const x1234 = (x123 + x234) / 2;
  const y1234 = (y123 + y234) / 2;
  if (level > 0) {
    let dx = x4 - x1;
    let dy = y4 - y1;
    const d2 = Math.abs((x2 - x4) * dy - (y2 - y4) * dx);
    const d3 = Math.abs((x3 - x4) * dy - (y3 - y4) * dx);
    let da1;
    let da2;
    if (d2 > FLT_EPSILON && d3 > FLT_EPSILON) {
      if ((d2 + d3) * (d2 + d3) <= distanceTolerance * (dx * dx + dy * dy)) {
        if (mAngleTolerance < curveAngleToleranceEpsilon) {
          points.push(x1234, y1234);
          return;
        }
        const a23 = Math.atan2(y3 - y2, x3 - x2);
        da1 = Math.abs(a23 - Math.atan2(y2 - y1, x2 - x1));
        da2 = Math.abs(Math.atan2(y4 - y3, x4 - x3) - a23);
        if (da1 >= pi) da1 = 2 * pi - da1;
        if (da2 >= pi) da2 = 2 * pi - da2;
        if (da1 + da2 < mAngleTolerance) {
          points.push(x1234, y1234);
          return;
        }
        if (mCuspLimit !== 0) {
          if (da1 > mCuspLimit) {
            points.push(x2, y2);
            return;
          }
          if (da2 > mCuspLimit) {
            points.push(x3, y3);
            return;
          }
        }
      }
    } else if (d2 > FLT_EPSILON) {
      if (d2 * d2 <= distanceTolerance * (dx * dx + dy * dy)) {
        if (mAngleTolerance < curveAngleToleranceEpsilon) {
          points.push(x1234, y1234);
          return;
        }
        da1 = Math.abs(Math.atan2(y3 - y2, x3 - x2) - Math.atan2(y2 - y1, x2 - x1));
        if (da1 >= pi) da1 = 2 * pi - da1;
        if (da1 < mAngleTolerance) {
          points.push(x2, y2);
          points.push(x3, y3);
          return;
        }
        if (mCuspLimit !== 0) {
          if (da1 > mCuspLimit) {
            points.push(x2, y2);
            return;
          }
        }
      }
    } else if (d3 > FLT_EPSILON) {
      if (d3 * d3 <= distanceTolerance * (dx * dx + dy * dy)) {
        if (mAngleTolerance < curveAngleToleranceEpsilon) {
          points.push(x1234, y1234);
          return;
        }
        da1 = Math.abs(Math.atan2(y4 - y3, x4 - x3) - Math.atan2(y3 - y2, x3 - x2));
        if (da1 >= pi) da1 = 2 * pi - da1;
        if (da1 < mAngleTolerance) {
          points.push(x2, y2);
          points.push(x3, y3);
          return;
        }
        if (mCuspLimit !== 0) {
          if (da1 > mCuspLimit) {
            points.push(x3, y3);
            return;
          }
        }
      }
    } else {
      dx = x1234 - (x1 + x4) / 2;
      dy = y1234 - (y1 + y4) / 2;
      if (dx * dx + dy * dy <= distanceTolerance) {
        points.push(x1234, y1234);
        return;
      }
    }
  }
  recursive(x1, y1, x12, y12, x123, y123, x1234, y1234, points, distanceTolerance, level + 1);
  recursive(x1234, y1234, x234, y234, x34, y34, x4, y4, points, distanceTolerance, level + 1);
}

exports.buildAdaptiveBezier = buildAdaptiveBezier;
//# sourceMappingURL=buildAdaptiveBezier.js.map
