import { Matrix } from '../../../maths/matrix/Matrix.mjs';
import { Bounds } from '../bounds/Bounds.mjs';
import { getGlobalBounds } from '../bounds/getGlobalBounds.mjs';
import { getLocalBounds } from '../bounds/getLocalBounds.mjs';
import { checkChildrenDidChange } from '../utils/checkChildrenDidChange.mjs';

"use strict";
const tempMatrix = new Matrix();
const measureMixin = {
  _localBoundsCacheId: -1,
  _localBoundsCacheData: null,
  _setWidth(value, localWidth) {
    const sign = Math.sign(this.scale.x) || 1;
    if (localWidth !== 0) {
      this.scale.x = value / localWidth * sign;
    } else {
      this.scale.x = sign;
    }
  },
  _setHeight(value, localHeight) {
    const sign = Math.sign(this.scale.y) || 1;
    if (localHeight !== 0) {
      this.scale.y = value / localHeight * sign;
    } else {
      this.scale.y = sign;
    }
  },
  getLocalBounds() {
    if (!this._localBoundsCacheData) {
      this._localBoundsCacheData = {
        data: [],
        index: 1,
        didChange: false,
        localBounds: new Bounds()
      };
    }
    const localBoundsCacheData = this._localBoundsCacheData;
    localBoundsCacheData.index = 1;
    localBoundsCacheData.didChange = false;
    if (localBoundsCacheData.data[0] !== this._didViewChangeTick) {
      localBoundsCacheData.didChange = true;
      localBoundsCacheData.data[0] = this._didViewChangeTick;
    }
    checkChildrenDidChange(this, localBoundsCacheData);
    if (localBoundsCacheData.didChange) {
      getLocalBounds(this, localBoundsCacheData.localBounds, tempMatrix);
    }
    return localBoundsCacheData.localBounds;
  },
  getBounds(skipUpdate, bounds) {
    return getGlobalBounds(this, skipUpdate, bounds || new Bounds());
  }
};

export { measureMixin };
//# sourceMappingURL=measureMixin.mjs.map
