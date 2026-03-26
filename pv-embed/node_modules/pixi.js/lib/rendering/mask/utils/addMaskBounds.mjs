import { Bounds } from '../../../scene/container/bounds/Bounds.mjs';
import { getGlobalBounds } from '../../../scene/container/bounds/getGlobalBounds.mjs';

"use strict";
const tempBounds = new Bounds();
function addMaskBounds(mask, bounds, skipUpdateTransform) {
  const boundsToMask = tempBounds;
  mask.measurable = true;
  getGlobalBounds(mask, skipUpdateTransform, boundsToMask);
  bounds.addBoundsMask(boundsToMask);
  mask.measurable = false;
}

export { addMaskBounds };
//# sourceMappingURL=addMaskBounds.mjs.map
