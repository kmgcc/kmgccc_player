'use strict';

"use strict";
class GlRenderTarget {
  constructor() {
    this.width = -1;
    this.height = -1;
    this.msaa = false;
    /**
     * Tracks which mip level is currently attached to this render target's framebuffer.
     * This lets us skip redundant framebufferTexture2D calls on the common path.
     * @internal
     */
    this._attachedMipLevel = 0;
    /**
     * Tracks which array layer (or cube face index) is currently attached to this render target's framebuffer.
     * For non-array 2D textures this will always be 0.
     * @internal
     */
    this._attachedLayer = 0;
    this.msaaRenderBuffer = [];
  }
}

exports.GlRenderTarget = GlRenderTarget;
//# sourceMappingURL=GlRenderTarget.js.map
