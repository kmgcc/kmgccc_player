'use strict';

var Extensions = require('../../../../../extensions/Extensions.js');
var TextureSource = require('./TextureSource.js');

"use strict";
class ImageSource extends TextureSource.TextureSource {
  constructor(options) {
    super(options);
    this.uploadMethodId = "image";
    this.autoGarbageCollect = true;
  }
  static test(resource) {
    return globalThis.HTMLImageElement && resource instanceof HTMLImageElement || typeof ImageBitmap !== "undefined" && resource instanceof ImageBitmap || globalThis.VideoFrame && resource instanceof VideoFrame;
  }
}
ImageSource.extension = Extensions.ExtensionType.TextureSource;

exports.ImageSource = ImageSource;
//# sourceMappingURL=ImageSource.js.map
