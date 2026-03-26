import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { AbstractTextSystem } from '../shared/AbstractTextSystem.mjs';

"use strict";
class CanvasRendererTextSystem extends AbstractTextSystem {
  constructor(renderer) {
    super(renderer, true);
  }
}
/** @ignore */
CanvasRendererTextSystem.extension = {
  type: [
    ExtensionType.CanvasSystem
  ],
  name: "canvasText"
};

export { CanvasRendererTextSystem };
//# sourceMappingURL=CanvasTextSystem.mjs.map
