import { Matrix } from '../../../maths/matrix/Matrix.mjs';
import { updateTransformBackwards } from '../bounds/getGlobalBounds.mjs';
import { matrixPool } from '../bounds/utils/matrixAndBoundsPool.mjs';
import { multiplyColors } from '../utils/multiplyColors.mjs';

"use strict";
function bgr2rgb(color) {
  return ((color & 255) << 16) + (color & 65280) + (color >> 16 & 255);
}
const getGlobalMixin = {
  getGlobalAlpha(skipUpdate) {
    if (skipUpdate) {
      if (this.renderGroup) {
        return this.renderGroup.worldAlpha;
      }
      if (this.parentRenderGroup) {
        return this.parentRenderGroup.worldAlpha * this.alpha;
      }
      return this.alpha;
    }
    let alpha = this.alpha;
    let current = this.parent;
    while (current) {
      alpha *= current.alpha;
      current = current.parent;
    }
    return alpha;
  },
  getGlobalTransform(matrix = new Matrix(), skipUpdate) {
    if (skipUpdate) {
      return matrix.copyFrom(this.worldTransform);
    }
    this.updateLocalTransform();
    const parentTransform = updateTransformBackwards(this, matrixPool.get().identity());
    matrix.appendFrom(this.localTransform, parentTransform);
    matrixPool.return(parentTransform);
    return matrix;
  },
  getGlobalTint(skipUpdate) {
    if (skipUpdate) {
      if (this.renderGroup) {
        return bgr2rgb(this.renderGroup.worldColor);
      }
      if (this.parentRenderGroup) {
        return bgr2rgb(
          multiplyColors(this.localColor, this.parentRenderGroup.worldColor)
        );
      }
      return this.tint;
    }
    let color = this.localColor;
    let parent = this.parent;
    while (parent) {
      color = multiplyColors(color, parent.localColor);
      parent = parent.parent;
    }
    return bgr2rgb(color);
  }
};

export { bgr2rgb, getGlobalMixin };
//# sourceMappingURL=getGlobalMixin.mjs.map
