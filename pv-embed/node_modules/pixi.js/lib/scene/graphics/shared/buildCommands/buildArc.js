'use strict';

"use strict";
function buildArc(points, x, y, radius, start, end, clockwise, steps) {
  let dist = Math.abs(start - end);
  if (!clockwise && start > end) {
    dist = 2 * Math.PI - dist;
  } else if (clockwise && end > start) {
    dist = 2 * Math.PI - dist;
  }
  steps || (steps = Math.max(6, Math.floor(6 * Math.pow(radius, 1 / 3) * (dist / Math.PI))));
  steps = Math.max(steps, 3);
  let f = dist / steps;
  let t = start;
  f *= clockwise ? -1 : 1;
  for (let i = 0; i < steps + 1; i++) {
    const cs = Math.cos(t);
    const sn = Math.sin(t);
    const nx = x + cs * radius;
    const ny = y + sn * radius;
    points.push(nx, ny);
    t += f;
  }
}

exports.buildArc = buildArc;
//# sourceMappingURL=buildArc.js.map
