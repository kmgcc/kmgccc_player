'use strict';

require('../../../maths/index.js');
var Matrix = require('../../../maths/matrix/Matrix.js');

"use strict";
const tempProjectionMatrix = new Matrix.Matrix();
function getGlobalRenderableBounds(renderables, bounds) {
  bounds.clear();
  const actualMatrix = bounds.matrix;
  for (let i = 0; i < renderables.length; i++) {
    const renderable = renderables[i];
    if (renderable.globalDisplayStatus < 7) {
      continue;
    }
    const renderGroup = renderable.renderGroup ?? renderable.parentRenderGroup;
    if (renderGroup?.isCachedAsTexture) {
      bounds.matrix = tempProjectionMatrix.copyFrom(renderGroup.textureOffsetInverseTransform).append(renderable.worldTransform);
    } else if (renderGroup?._parentCacheAsTextureRenderGroup) {
      bounds.matrix = tempProjectionMatrix.copyFrom(renderGroup._parentCacheAsTextureRenderGroup.inverseWorldTransform).append(renderable.groupTransform);
    } else {
      bounds.matrix = renderable.worldTransform;
    }
    bounds.addBounds(renderable.bounds);
  }
  bounds.matrix = actualMatrix;
  return bounds;
}

exports.getGlobalRenderableBounds = getGlobalRenderableBounds;
//# sourceMappingURL=getRenderableBounds.js.map
