'use strict';

"use strict";
function multiplyHexColors(color1, color2) {
  if (color1 === 16777215 || !color2) return color2;
  if (color2 === 16777215 || !color1) return color1;
  const r1 = color1 >> 16 & 255;
  const g1 = color1 >> 8 & 255;
  const b1 = color1 & 255;
  const r2 = color2 >> 16 & 255;
  const g2 = color2 >> 8 & 255;
  const b2 = color2 & 255;
  const r = r1 * r2 / 255 | 0;
  const g = g1 * g2 / 255 | 0;
  const b = b1 * b2 / 255 | 0;
  return (r << 16) + (g << 8) + b;
}

exports.multiplyHexColors = multiplyHexColors;
//# sourceMappingURL=multiplyHexColors.js.map
