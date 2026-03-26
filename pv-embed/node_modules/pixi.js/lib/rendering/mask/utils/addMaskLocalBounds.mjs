import { getLocalBounds } from '../../../scene/container/bounds/getLocalBounds.mjs';
import { boundsPool, matrixPool } from '../../../scene/container/bounds/utils/matrixAndBoundsPool.mjs';
import { warn } from '../../../utils/logging/warn.mjs';

"use strict";
function addMaskLocalBounds(mask, bounds, localRoot) {
  const boundsToMask = boundsPool.get();
  mask.measurable = true;
  const tempMatrix = matrixPool.get().identity();
  const relativeMask = getMatrixRelativeToParent(mask, localRoot, tempMatrix);
  getLocalBounds(mask, boundsToMask, relativeMask);
  mask.measurable = false;
  bounds.addBoundsMask(boundsToMask);
  matrixPool.return(tempMatrix);
  boundsPool.return(boundsToMask);
}
function getMatrixRelativeToParent(target, root, matrix) {
  if (!target) {
    warn("Mask bounds, renderable is not inside the root container");
    return matrix;
  }
  if (target !== root) {
    getMatrixRelativeToParent(target.parent, root, matrix);
    target.updateLocalTransform();
    matrix.append(target.localTransform);
  }
  return matrix;
}

export { addMaskLocalBounds };
//# sourceMappingURL=addMaskLocalBounds.mjs.map
