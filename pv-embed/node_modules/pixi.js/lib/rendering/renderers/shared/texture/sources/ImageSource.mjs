import { ExtensionType } from '../../../../../extensions/Extensions.mjs';
import { TextureSource } from './TextureSource.mjs';

"use strict";
class ImageSource extends TextureSource {
  constructor(options) {
    super(options);
    this.uploadMethodId = "image";
    this.autoGarbageCollect = true;
  }
  static test(resource) {
    return globalThis.HTMLImageElement && resource instanceof HTMLImageElement || typeof ImageBitmap !== "undefined" && resource instanceof ImageBitmap || globalThis.VideoFrame && resource instanceof VideoFrame;
  }
}
ImageSource.extension = ExtensionType.TextureSource;

export { ImageSource };
//# sourceMappingURL=ImageSource.mjs.map
