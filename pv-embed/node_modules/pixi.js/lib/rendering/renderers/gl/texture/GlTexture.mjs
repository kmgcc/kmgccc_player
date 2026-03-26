import { GL_TARGETS, GL_TYPES, GL_FORMATS } from './const.mjs';

"use strict";
class GlTexture {
  constructor(texture) {
    this.target = GL_TARGETS.TEXTURE_2D;
    /**
     * Bitmask tracking which array layers / sub-targets have been initialized at mip level 0.
     * Used by uploaders that need per-layer allocation semantics (e.g. cube faces).
     * @internal
     */
    this._layerInitMask = 0;
    this.texture = texture;
    this.width = -1;
    this.height = -1;
    this.type = GL_TYPES.UNSIGNED_BYTE;
    this.internalFormat = GL_FORMATS.RGBA;
    this.format = GL_FORMATS.RGBA;
    this.samplerType = 0;
  }
  destroy() {
  }
}

export { GlTexture };
//# sourceMappingURL=GlTexture.mjs.map
