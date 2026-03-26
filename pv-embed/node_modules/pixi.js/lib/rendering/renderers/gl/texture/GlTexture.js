'use strict';

var _const = require('./const.js');

"use strict";
class GlTexture {
  constructor(texture) {
    this.target = _const.GL_TARGETS.TEXTURE_2D;
    /**
     * Bitmask tracking which array layers / sub-targets have been initialized at mip level 0.
     * Used by uploaders that need per-layer allocation semantics (e.g. cube faces).
     * @internal
     */
    this._layerInitMask = 0;
    this.texture = texture;
    this.width = -1;
    this.height = -1;
    this.type = _const.GL_TYPES.UNSIGNED_BYTE;
    this.internalFormat = _const.GL_FORMATS.RGBA;
    this.format = _const.GL_FORMATS.RGBA;
    this.samplerType = 0;
  }
  destroy() {
  }
}

exports.GlTexture = GlTexture;
//# sourceMappingURL=GlTexture.js.map
