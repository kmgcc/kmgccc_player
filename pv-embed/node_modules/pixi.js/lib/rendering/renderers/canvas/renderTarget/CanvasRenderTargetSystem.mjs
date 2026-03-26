import { ExtensionType } from '../../../../extensions/Extensions.mjs';
import { RenderTargetSystem } from '../../shared/renderTarget/RenderTargetSystem.mjs';
import { CanvasRenderTargetAdaptor } from './CanvasRenderTargetAdaptor.mjs';

"use strict";
class CanvasRenderTargetSystem extends RenderTargetSystem {
  constructor(renderer) {
    super(renderer);
    this.adaptor = new CanvasRenderTargetAdaptor();
    this.adaptor.init(renderer, this);
  }
}
/** @ignore */
CanvasRenderTargetSystem.extension = {
  type: [ExtensionType.CanvasSystem],
  name: "renderTarget"
};

export { CanvasRenderTargetSystem };
//# sourceMappingURL=CanvasRenderTargetSystem.mjs.map
