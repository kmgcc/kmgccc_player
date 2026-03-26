import { GraphicsContextSystem } from '../GraphicsContextSystem.mjs';

"use strict";
const RECURSION_LIMIT = 8;
const FLT_EPSILON = 11920929e-14;
const PATH_DISTANCE_EPSILON = 1;
const curveAngleToleranceEpsilon = 0.01;
const mAngleTolerance = 0;
function buildAdaptiveQuadratic(points, sX, sY, cp1x, cp1y, eX, eY, smoothness) {
  const scale = 1;
  const smoothing = Math.min(
    0.99,
    // a value of 1.0 actually inverts smoothing, so we cap it at 0.99
    Math.max(0, smoothness ?? GraphicsContextSystem.defaultOptions.bezierSmoothness)
  );
  let distanceTolerance = (PATH_DISTANCE_EPSILON - smoothing) / scale;
  distanceTolerance *= distanceTolerance;
  begin(sX, sY, cp1x, cp1y, eX, eY, points, distanceTolerance);
  return points;
}
function begin(sX, sY, cp1x, cp1y, eX, eY, points, distanceTolerance) {
  recursive(points, sX, sY, cp1x, cp1y, eX, eY, distanceTolerance, 0);
  points.push(eX, eY);
}
function recursive(points, x1, y1, x2, y2, x3, y3, distanceTolerance, level) {
  if (level > RECURSION_LIMIT) {
    return;
  }
  const pi = Math.PI;
  const x12 = (x1 + x2) / 2;
  const y12 = (y1 + y2) / 2;
  const x23 = (x2 + x3) / 2;
  const y23 = (y2 + y3) / 2;
  const x123 = (x12 + x23) / 2;
  const y123 = (y12 + y23) / 2;
  let dx = x3 - x1;
  let dy = y3 - y1;
  const d = Math.abs((x2 - x3) * dy - (y2 - y3) * dx);
  if (d > FLT_EPSILON) {
    if (d * d <= distanceTolerance * (dx * dx + dy * dy)) {
      if (mAngleTolerance < curveAngleToleranceEpsilon) {
        points.push(x123, y123);
        return;
      }
      let da = Math.abs(Math.atan2(y3 - y2, x3 - x2) - Math.atan2(y2 - y1, x2 - x1));
      if (da >= pi) da = 2 * pi - da;
      if (da < mAngleTolerance) {
        points.push(x123, y123);
        return;
      }
    }
  } else {
    dx = x123 - (x1 + x3) / 2;
    dy = y123 - (y1 + y3) / 2;
    if (dx * dx + dy * dy <= distanceTolerance) {
      points.push(x123, y123);
      return;
    }
  }
  recursive(points, x1, y1, x12, y12, x123, y123, distanceTolerance, level + 1);
  recursive(points, x123, y123, x23, y23, x3, y3, distanceTolerance, level + 1);
}

export { buildAdaptiveQuadratic };
//# sourceMappingURL=buildAdaptiveQuadratic.mjs.map
