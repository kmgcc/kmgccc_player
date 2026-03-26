'use strict';

var Extensions = require('../../../extensions/Extensions.js');

"use strict";
class GlColorMaskSystem {
  constructor(renderer) {
    this._colorMaskCache = 15;
    this._renderer = renderer;
  }
  setMask(colorMask) {
    if (this._colorMaskCache === colorMask) return;
    this._colorMaskCache = colorMask;
    this._renderer.gl.colorMask(
      !!(colorMask & 8),
      !!(colorMask & 4),
      !!(colorMask & 2),
      !!(colorMask & 1)
    );
  }
}
/** @ignore */
GlColorMaskSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem
  ],
  name: "colorMask"
};

exports.GlColorMaskSystem = GlColorMaskSystem;
//# sourceMappingURL=GlColorMaskSystem.js.map
