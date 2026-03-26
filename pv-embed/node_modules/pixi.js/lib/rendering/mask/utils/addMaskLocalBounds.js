'use strict';

var getLocalBounds = require('../../../scene/container/bounds/getLocalBounds.js');
var matrixAndBoundsPool = require('../../../scene/container/bounds/utils/matrixAndBoundsPool.js');
var warn = require('../../../utils/logging/warn.js');

"use strict";
function addMaskLocalBounds(mask, bounds, localRoot) {
  const boundsToMask = matrixAndBoundsPool.boundsPool.get();
  mask.measurable = true;
  const tempMatrix = matrixAndBoundsPool.matrixPool.get().identity();
  const relativeMask = getMatrixRelativeToParent(mask, localRoot, tempMatrix);
  getLocalBounds.getLocalBounds(mask, boundsToMask, relativeMask);
  mask.measurable = false;
  bounds.addBoundsMask(boundsToMask);
  matrixAndBoundsPool.matrixPool.return(tempMatrix);
  matrixAndBoundsPool.boundsPool.return(boundsToMask);
}
function getMatrixRelativeToParent(target, root, matrix) {
  if (!target) {
    warn.warn("Mask bounds, renderable is not inside the root container");
    return matrix;
  }
  if (target !== root) {
    getMatrixRelativeToParent(target.parent, root, matrix);
    target.updateLocalTransform();
    matrix.append(target.localTransform);
  }
  return matrix;
}

exports.addMaskLocalBounds = addMaskLocalBounds;
//# sourceMappingURL=addMaskLocalBounds.js.map
