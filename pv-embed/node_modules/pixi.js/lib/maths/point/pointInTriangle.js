'use strict';

"use strict";
function pointInTriangle(px, py, x1, y1, x2, y2, x3, y3) {
  const v2x = x3 - x1;
  const v2y = y3 - y1;
  const v1x = x2 - x1;
  const v1y = y2 - y1;
  const v0x = px - x1;
  const v0y = py - y1;
  const dot00 = v2x * v2x + v2y * v2y;
  const dot01 = v2x * v1x + v2y * v1y;
  const dot02 = v2x * v0x + v2y * v0y;
  const dot11 = v1x * v1x + v1y * v1y;
  const dot12 = v1x * v0x + v1y * v0y;
  const invDenom = 1 / (dot00 * dot11 - dot01 * dot01);
  const u = (dot11 * dot02 - dot01 * dot12) * invDenom;
  const v = (dot00 * dot12 - dot01 * dot02) * invDenom;
  return u >= 0 && v >= 0 && u + v < 1;
}

exports.pointInTriangle = pointInTriangle;
//# sourceMappingURL=pointInTriangle.js.map
