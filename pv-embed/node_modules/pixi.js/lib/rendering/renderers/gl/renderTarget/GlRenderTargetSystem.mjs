import { ExtensionType } from '../../../../extensions/Extensions.mjs';
import { RenderTargetSystem } from '../../shared/renderTarget/RenderTargetSystem.mjs';
import { GlRenderTargetAdaptor } from './GlRenderTargetAdaptor.mjs';

"use strict";
class GlRenderTargetSystem extends RenderTargetSystem {
  constructor(renderer) {
    super(renderer);
    this.adaptor = new GlRenderTargetAdaptor();
    this.adaptor.init(renderer, this);
  }
}
/** @ignore */
GlRenderTargetSystem.extension = {
  type: [ExtensionType.WebGLSystem],
  name: "renderTarget"
};

export { GlRenderTargetSystem };
//# sourceMappingURL=GlRenderTargetSystem.mjs.map
