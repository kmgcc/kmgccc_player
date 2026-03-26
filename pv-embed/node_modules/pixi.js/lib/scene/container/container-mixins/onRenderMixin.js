'use strict';

"use strict";
const onRenderMixin = {
  _onRender: null,
  set onRender(func) {
    const renderGroup = this.renderGroup || this.parentRenderGroup;
    if (!func) {
      if (this._onRender) {
        renderGroup?.removeOnRender(this);
      }
      this._onRender = null;
      return;
    }
    if (!this._onRender) {
      renderGroup?.addOnRender(this);
    }
    this._onRender = func;
  },
  get onRender() {
    return this._onRender;
  }
};

exports.onRenderMixin = onRenderMixin;
//# sourceMappingURL=onRenderMixin.js.map
