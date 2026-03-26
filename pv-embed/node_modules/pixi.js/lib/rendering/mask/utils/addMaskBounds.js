'use strict';

var Bounds = require('../../../scene/container/bounds/Bounds.js');
var getGlobalBounds = require('../../../scene/container/bounds/getGlobalBounds.js');

"use strict";
const tempBounds = new Bounds.Bounds();
function addMaskBounds(mask, bounds, skipUpdateTransform) {
  const boundsToMask = tempBounds;
  mask.measurable = true;
  getGlobalBounds.getGlobalBounds(mask, skipUpdateTransform, boundsToMask);
  bounds.addBoundsMask(boundsToMask);
  mask.measurable = false;
}

exports.addMaskBounds = addMaskBounds;
//# sourceMappingURL=addMaskBounds.js.map
