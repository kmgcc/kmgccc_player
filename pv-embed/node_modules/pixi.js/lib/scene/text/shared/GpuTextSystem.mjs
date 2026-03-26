import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { AbstractTextSystem } from './AbstractTextSystem.mjs';

"use strict";
class CanvasTextSystem extends AbstractTextSystem {
  constructor(renderer) {
    super(renderer, false);
  }
}
/** @ignore */
CanvasTextSystem.extension = {
  type: [
    ExtensionType.WebGLSystem,
    ExtensionType.WebGPUSystem
  ],
  name: "canvasText"
};

export { CanvasTextSystem };
//# sourceMappingURL=GpuTextSystem.mjs.map
