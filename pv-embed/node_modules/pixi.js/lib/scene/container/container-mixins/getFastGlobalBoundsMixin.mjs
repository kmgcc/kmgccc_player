import { Matrix } from '../../../maths/matrix/Matrix.mjs';
import { Bounds } from '../bounds/Bounds.mjs';
import { boundsPool } from '../bounds/utils/matrixAndBoundsPool.mjs';

"use strict";
const tempMatrix = new Matrix();
const getFastGlobalBoundsMixin = {
  getFastGlobalBounds(factorRenderLayers, bounds) {
    bounds || (bounds = new Bounds());
    bounds.clear();
    this._getGlobalBoundsRecursive(!!factorRenderLayers, bounds, this.parentRenderLayer);
    if (!bounds.isValid) {
      bounds.set(0, 0, 0, 0);
    }
    const renderGroup = this.renderGroup || this.parentRenderGroup;
    bounds.applyMatrix(renderGroup.worldTransform);
    return bounds;
  },
  _getGlobalBoundsRecursive(factorRenderLayers, bounds, currentLayer) {
    let localBounds = bounds;
    if (factorRenderLayers && this.parentRenderLayer && this.parentRenderLayer !== currentLayer) return;
    if (this.localDisplayStatus !== 7 || !this.measurable) {
      return;
    }
    const manageEffects = !!this.effects.length;
    if (this.renderGroup || manageEffects) {
      localBounds = boundsPool.get().clear();
    }
    if (this.boundsArea) {
      bounds.addRect(this.boundsArea, this.worldTransform);
    } else {
      if (this.renderPipeId) {
        const viewBounds = this.bounds;
        localBounds.addFrame(
          viewBounds.minX,
          viewBounds.minY,
          viewBounds.maxX,
          viewBounds.maxY,
          this.groupTransform
        );
      }
      const children = this.children;
      for (let i = 0; i < children.length; i++) {
        children[i]._getGlobalBoundsRecursive(factorRenderLayers, localBounds, currentLayer);
      }
    }
    if (manageEffects) {
      let advanced = false;
      const renderGroup = this.renderGroup || this.parentRenderGroup;
      for (let i = 0; i < this.effects.length; i++) {
        if (this.effects[i].addBounds) {
          if (!advanced) {
            advanced = true;
            localBounds.applyMatrix(renderGroup.worldTransform);
          }
          this.effects[i].addBounds(localBounds, true);
        }
      }
      if (advanced) {
        localBounds.applyMatrix(renderGroup.worldTransform.copyTo(tempMatrix).invert());
      }
      bounds.addBounds(localBounds);
      boundsPool.return(localBounds);
    } else if (this.renderGroup) {
      bounds.addBounds(localBounds, this.relativeGroupTransform);
      boundsPool.return(localBounds);
    }
  }
};

export { getFastGlobalBoundsMixin };
//# sourceMappingURL=getFastGlobalBoundsMixin.mjs.map
