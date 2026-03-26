'use strict';

var deprecation = require('../../../utils/logging/deprecation.js');

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
    deprecation.deprecation("v8.6.0", "cacheAsBitmap is deprecated, use cacheAsTexture instead.");
    this.cacheAsTexture(val);
  }
};

exports.cacheAsTextureMixin = cacheAsTextureMixin;
//# sourceMappingURL=cacheAsTextureMixin.js.map
