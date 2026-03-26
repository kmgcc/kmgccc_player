'use strict';

var Extensions = require('../../extensions/Extensions.js');
var SdfShader = require('../text/sdfShader/SdfShader.js');
var AbstractBitmapTextPipe = require('./AbstractBitmapTextPipe.js');

"use strict";
class BitmapTextPipe extends AbstractBitmapTextPipe.AbstractBitmapTextPipe {
  getSdfShader() {
    return new SdfShader.SdfShader(this._renderer.limits.maxBatchableTextures);
  }
}
/** @ignore */
BitmapTextPipe.extension = {
  type: [
    Extensions.ExtensionType.WebGLPipes,
    Extensions.ExtensionType.WebGPUPipes
  ],
  name: "bitmapText"
};

exports.BitmapTextPipe = BitmapTextPipe;
//# sourceMappingURL=GpuBitmapTextPipe.js.map
