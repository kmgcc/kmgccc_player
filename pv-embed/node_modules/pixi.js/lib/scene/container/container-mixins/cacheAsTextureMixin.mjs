import { deprecation } from '../../../utils/logging/deprecation.mjs';

"use strict";
const cacheAsTextureMixin = {
  get isCachedAsTexture() {
    return !!this.renderGroup?.isCachedAsTexture;
  },
  cacheAsTexture(val) {
    if (typeof val === "boolean" && val === false) {
      this.disableRenderGroup();
    } else {
      this.enableRenderGroup();
      this.renderGroup.enableCacheAsTexture(val === true ? {} : val);
    }
  },
  updateCacheTexture() {
    this.renderGroup?.updateCacheTexture();
  },
  get cacheAsBitmap() {
    return this.isCachedAsTexture;
  },
  set cacheAsBitmap(val) {
    deprecation("v8.6.0", "cacheAsBitmap is deprecated, use cacheAsTexture instead.");
    this.cacheAsTexture(val);
  }
};

export { cacheAsTextureMixin };
//# sourceMappingURL=cacheAsTextureMixin.mjs.map
