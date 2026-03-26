'use strict';

"use strict";
class GlBuffer {
  constructor(buffer, type) {
    this._lastBindBaseLocation = -1;
    this._lastBindCallId = -1;
    this.buffer = buffer || null;
    this.updateID = -1;
    this.byteLength = -1;
    this.type = type;
  }
  destroy() {
    this.buffer = null;
    this.updateID = -1;
    this.byteLength = -1;
    this.type = -1;
    this._lastBindBaseLocation = -1;
    this._lastBindCallId = -1;
  }
}

exports.GlBuffer = GlBuffer;
//# sourceMappingURL=GlBuffer.js.map
