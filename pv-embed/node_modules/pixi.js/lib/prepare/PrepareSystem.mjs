import { ExtensionType } from '../extensions/Extensions.mjs';
import { PrepareUpload } from './PrepareUpload.mjs';

"use strict";
class PrepareSystem extends PrepareUpload {
  /** Destroys the plugin, don't use after this. */
  destroy() {
    super.destroy();
    clearTimeout(this.timeout);
    this.renderer = null;
    this.queue = null;
    this.resolves = null;
  }
}
/** @ignore */
PrepareSystem.extension = {
  type: [
    ExtensionType.WebGLSystem,
    ExtensionType.WebGPUSystem
  ],
  name: "prepare"
};

export { PrepareSystem };
//# sourceMappingURL=PrepareSystem.mjs.map
