import { ExtensionType } from '../../../extensions/Extensions.mjs';

"use strict";
class ColorMask {
  constructor(options) {
    this.priority = 0;
    this.pipe = "colorMask";
    if (options?.mask) {
      this.init(options.mask);
    }
  }
  init(mask) {
    this.mask = mask;
  }
  destroy() {
  }
  static test(mask) {
    return typeof mask === "number";
  }
}
ColorMask.extension = ExtensionType.MaskEffect;

export { ColorMask };
//# sourceMappingURL=ColorMask.mjs.map
