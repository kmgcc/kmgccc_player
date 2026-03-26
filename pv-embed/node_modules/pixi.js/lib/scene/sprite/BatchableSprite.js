'use strict';

"use strict";
class BatchableSprite {
  constructor() {
    this.batcherName = "default";
    this.topology = "triangle-list";
    // batch specific..
    this.attributeSize = 4;
    this.indexSize = 6;
    this.packAsQuad = true;
    this.roundPixels = 0;
    this._attributeStart = 0;
    // location in the buffer
    this._batcher = null;
    this._batch = null;
  }
  get blendMode() {
    return this.renderable.groupBlendMode;
  }
  get color() {
    return this.renderable.groupColorAlpha;
  }
  reset() {
    this.renderable = null;
    this.texture = null;
    this._batcher = null;
    this._batch = null;
    this.bounds = null;
  }
  destroy() {
    this.reset();
  }
}

exports.BatchableSprite = BatchableSprite;
//# sourceMappingURL=BatchableSprite.js.map
