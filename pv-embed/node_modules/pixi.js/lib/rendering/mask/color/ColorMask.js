'use strict';

var Extensions = require('../../../extensions/Extensions.js');

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
ColorMask.extension = Extensions.ExtensionType.MaskEffect;

exports.ColorMask = ColorMask;
//# sourceMappingURL=ColorMask.js.map
