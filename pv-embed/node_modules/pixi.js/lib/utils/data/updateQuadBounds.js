'use strict';

"use strict";
function updateQuadBounds(bounds, anchor, texture) {
  const { width, height } = texture.orig;
  const trim = texture.trim;
  if (trim) {
    const sourceWidth = trim.width;
    const sourceHeight = trim.height;
    bounds.minX = trim.x - anchor._x * width;
    bounds.maxX = bounds.minX + sourceWidth;
    bounds.minY = trim.y - anchor._y * height;
    bounds.maxY = bounds.minY + sourceHeight;
  } else {
    bounds.minX = -anchor._x * width;
    bounds.maxX = bounds.minX + width;
    bounds.minY = -anchor._y * height;
    bounds.maxY = bounds.minY + height;
  }
}

exports.updateQuadBounds = updateQuadBounds;
//# sourceMappingURL=updateQuadBounds.js.map
