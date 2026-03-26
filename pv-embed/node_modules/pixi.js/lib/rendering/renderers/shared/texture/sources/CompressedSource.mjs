import { TextureSource } from './TextureSource.mjs';

"use strict";
class CompressedSource extends TextureSource {
  constructor(options) {
    super({
      ...options,
      mipLevelCount: options.resource.length
    });
    this.uploadMethodId = "compressed";
  }
}

export { CompressedSource };
//# sourceMappingURL=CompressedSource.mjs.map
