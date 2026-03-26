'use strict';

"use strict";
function calculateProjection(pm, x, y, width, height, flipY) {
  const sign = flipY ? 1 : -1;
  pm.identity();
  pm.a = 1 / width * 2;
  pm.d = sign * (1 / height * 2);
  pm.tx = -1 - x * pm.a;
  pm.ty = -sign - y * pm.d;
  return pm;
}

exports.calculateProjection = calculateProjection;
//# sourceMappingURL=calculateProjection.js.map
