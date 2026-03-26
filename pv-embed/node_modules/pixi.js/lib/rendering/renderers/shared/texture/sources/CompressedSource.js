'use strict';

var TextureSource = require('./TextureSource.js');

"use strict";
class CompressedSource extends TextureSource.TextureSource {
  constructor(options) {
    super({
      ...options,
      mipLevelCount: options.resource.length
    });
    this.uploadMethodId = "compressed";
  }
}

exports.CompressedSource = CompressedSource;
//# sourceMappingURL=CompressedSource.js.map
