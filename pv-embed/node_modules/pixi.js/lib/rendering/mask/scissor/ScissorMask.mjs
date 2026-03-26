import { addMaskBounds } from '../utils/addMaskBounds.mjs';
import { addMaskLocalBounds } from '../utils/addMaskLocalBounds.mjs';

"use strict";
class ScissorMask {
  constructor(mask) {
    this.priority = 0;
    this.pipe = "scissorMask";
    this.mask = mask;
    this.mask.renderable = false;
    this.mask.measurable = false;
  }
  addBounds(bounds, skipUpdateTransform) {
    addMaskBounds(this.mask, bounds, skipUpdateTransform);
  }
  addLocalBounds(bounds, localRoot) {
    addMaskLocalBounds(this.mask, bounds, localRoot);
  }
  containsPoint(point, hitTestFn) {
    const mask = this.mask;
    return hitTestFn(mask, point);
  }
  reset() {
    if (this.mask === null) return;
    this.mask.measurable = true;
    this.mask = null;
  }
  destroy() {
    this.reset();
  }
}

export { ScissorMask };
//# sourceMappingURL=ScissorMask.mjs.map
