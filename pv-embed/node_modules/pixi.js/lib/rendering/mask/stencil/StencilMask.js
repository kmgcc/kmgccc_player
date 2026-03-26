'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var Container = require('../../../scene/container/Container.js');
var addMaskBounds = require('../utils/addMaskBounds.js');
var addMaskLocalBounds = require('../utils/addMaskLocalBounds.js');

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
    addMaskBounds.addMaskBounds(this.mask, bounds, skipUpdateTransform);
  }
  addLocalBounds(bounds, localRoot) {
    addMaskLocalBounds.addMaskLocalBounds(this.mask, bounds, localRoot);
  }
  containsPoint(point, hitTestFn) {
    const mask = this.mask;
    return hitTestFn(mask, point);
  }
  destroy() {
    this.reset();
  }
  static test(mask) {
    return mask instanceof Container.Container;
  }
}
StencilMask.extension = Extensions.ExtensionType.MaskEffect;

exports.StencilMask = StencilMask;
//# sourceMappingURL=StencilMask.js.map
