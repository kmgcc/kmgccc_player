'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var Sprite = require('../../../scene/sprite/Sprite.js');
var addMaskBounds = require('../utils/addMaskBounds.js');
var addMaskLocalBounds = require('../utils/addMaskLocalBounds.js');

"use strict";
class AlphaMask {
  constructor(options) {
    this.priority = 0;
    this.inverse = false;
    this.pipe = "alphaMask";
    if (options?.mask) {
      this.init(options.mask);
    }
  }
  init(mask) {
    this.mask = mask;
    this.renderMaskToTexture = !(mask instanceof Sprite.Sprite);
    this.mask.renderable = this.renderMaskToTexture;
    this.mask.includeInBuild = !this.renderMaskToTexture;
    this.mask.measurable = false;
  }
  reset() {
    if (this.mask === null) return;
    this.mask.measurable = true;
    this.mask = null;
  }
  addBounds(bounds, skipUpdateTransform) {
    if (!this.inverse) {
      addMaskBounds.addMaskBounds(this.mask, bounds, skipUpdateTransform);
    }
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
    return mask instanceof Sprite.Sprite;
  }
}
AlphaMask.extension = Extensions.ExtensionType.MaskEffect;

exports.AlphaMask = AlphaMask;
//# sourceMappingURL=AlphaMask.js.map
