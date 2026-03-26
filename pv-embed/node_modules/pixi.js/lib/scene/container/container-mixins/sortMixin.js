'use strict';

"use strict";
const sortMixin = {
  _zIndex: 0,
  sortDirty: false,
  sortableChildren: false,
  get zIndex() {
    return this._zIndex;
  },
  set zIndex(value) {
    if (this._zIndex === value) return;
    this._zIndex = value;
    this.depthOfChildModified();
  },
  depthOfChildModified() {
    if (this.parent) {
      this.parent.sortableChildren = true;
      this.parent.sortDirty = true;
    }
    if (this.parentRenderGroup) {
      this.parentRenderGroup.structureDidChange = true;
    }
  },
  sortChildren() {
    if (!this.sortDirty) return;
    this.sortDirty = false;
    this.children.sort(sortChildren);
  }
};
function sortChildren(a, b) {
  return a._zIndex - b._zIndex;
}

exports.sortMixin = sortMixin;
//# sourceMappingURL=sortMixin.js.map
