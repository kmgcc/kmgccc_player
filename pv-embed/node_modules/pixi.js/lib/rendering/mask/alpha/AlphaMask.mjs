import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { Sprite } from '../../../scene/sprite/Sprite.mjs';
import { addMaskBounds } from '../utils/addMaskBounds.mjs';
import { addMaskLocalBounds } from '../utils/addMaskLocalBounds.mjs';

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
    this.renderMaskToTexture = !(mask instanceof Sprite);
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
      addMaskBounds(this.mask, bounds, skipUpdateTransform);
    }
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
    return mask instanceof Sprite;
  }
}
AlphaMask.extension = ExtensionType.MaskEffect;

export { AlphaMask };
//# sourceMappingURL=AlphaMask.mjs.map
