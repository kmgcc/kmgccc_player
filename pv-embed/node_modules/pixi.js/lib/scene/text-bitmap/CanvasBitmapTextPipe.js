'use strict';

var Extensions = require('../../extensions/Extensions.js');
var AbstractBitmapTextPipe = require('./AbstractBitmapTextPipe.js');

"use strict";
class CanvasBitmapTextPipe extends AbstractBitmapTextPipe.AbstractBitmapTextPipe {
  getSdfShader() {
    return null;
  }
}
/** @ignore */
CanvasBitmapTextPipe.extension = {
  type: [
    Extensions.ExtensionType.CanvasPipes
  ],
  name: "bitmapText"
};

exports.CanvasBitmapTextPipe = CanvasBitmapTextPipe;
//# sourceMappingURL=CanvasBitmapTextPipe.js.map
