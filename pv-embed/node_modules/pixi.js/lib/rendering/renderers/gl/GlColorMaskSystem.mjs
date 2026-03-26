import { ExtensionType } from '../../../extensions/Extensions.mjs';

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
    ExtensionType.WebGLSystem
  ],
  name: "colorMask"
};

export { GlColorMaskSystem };
//# sourceMappingURL=GlColorMaskSystem.mjs.map
