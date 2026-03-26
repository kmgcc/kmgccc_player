import { updateQuadBounds } from '../../../utils/data/updateQuadBounds.mjs';

"use strict";
function updateTextBounds(batchableSprite, text) {
  const { texture, bounds } = batchableSprite;
  const padding = text._style._getFinalPadding();
  updateQuadBounds(bounds, text._anchor, texture);
  const paddingOffset = text._anchor._x * padding * 2;
  const paddingOffsetY = text._anchor._y * padding * 2;
  bounds.minX -= padding - paddingOffset;
  bounds.minY -= padding - paddingOffsetY;
  bounds.maxX -= padding - paddingOffset;
  bounds.maxY -= padding - paddingOffsetY;
}

export { updateTextBounds };
//# sourceMappingURL=updateTextBounds.mjs.map
