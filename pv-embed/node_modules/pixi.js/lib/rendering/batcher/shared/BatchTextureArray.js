'use strict';

"use strict";
class BatchTextureArray {
  constructor() {
    /** Respective locations for textures. */
    this.ids = /* @__PURE__ */ Object.create(null);
    this.textures = [];
    this.count = 0;
  }
  /** Clear the textures and their locations. */
  clear() {
    for (let i = 0; i < this.count; i++) {
      const t = this.textures[i];
      this.textures[i] = null;
      this.ids[t.uid] = null;
    }
    this.count = 0;
  }
}

exports.BatchTextureArray = BatchTextureArray;
//# sourceMappingURL=BatchTextureArray.js.map
