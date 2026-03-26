import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { Container } from '../../../scene/container/Container.mjs';
import { addMaskBounds } from '../utils/addMaskBounds.mjs';
import { addMaskLocalBounds } from '../utils/addMaskLocalBounds.mjs';

"use strict";
class StencilMask {
  constructor(options) {
    this.priority = 0;
    this.pipe = "stencilMask";
    if (options?.mask) {
      this.init(options.mask);
    }
  }
  init(mask) {
    this.mask = mask;
    this.mask.includeInBuild = false;
    this.mask.measurable = false;
  }
  reset() {
    if (this.mask === null) return;
    this.mask.measurable = true;
    this.mask.includeInBuild = true;
    this.mask = null;
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
  destroy() {
    this.reset();
  }
  static test(mask) {
    return mask instanceof Container;
  }
}
StencilMask.extension = ExtensionType.MaskEffect;

export { StencilMask };
//# sourceMappingURL=StencilMask.mjs.map
