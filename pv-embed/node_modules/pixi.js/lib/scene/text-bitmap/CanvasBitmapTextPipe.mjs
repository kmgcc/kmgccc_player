import { ExtensionType } from '../../extensions/Extensions.mjs';
import { AbstractBitmapTextPipe } from './AbstractBitmapTextPipe.mjs';

"use strict";
class CanvasBitmapTextPipe extends AbstractBitmapTextPipe {
  getSdfShader() {
    return null;
  }
}
/** @ignore */
CanvasBitmapTextPipe.extension = {
  type: [
    ExtensionType.CanvasPipes
  ],
  name: "bitmapText"
};

export { CanvasBitmapTextPipe };
//# sourceMappingURL=CanvasBitmapTextPipe.mjs.map
