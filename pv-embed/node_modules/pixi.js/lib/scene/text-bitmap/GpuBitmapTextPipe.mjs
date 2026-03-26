import { ExtensionType } from '../../extensions/Extensions.mjs';
import { SdfShader } from '../text/sdfShader/SdfShader.mjs';
import { AbstractBitmapTextPipe } from './AbstractBitmapTextPipe.mjs';

"use strict";
class BitmapTextPipe extends AbstractBitmapTextPipe {
  getSdfShader() {
    return new SdfShader(this._renderer.limits.maxBatchableTextures);
  }
}
/** @ignore */
BitmapTextPipe.extension = {
  type: [
    ExtensionType.WebGLPipes,
    ExtensionType.WebGPUPipes
  ],
  name: "bitmapText"
};

export { BitmapTextPipe };
//# sourceMappingURL=GpuBitmapTextPipe.mjs.map
