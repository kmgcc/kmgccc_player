import { ExtensionType } from '../../../../extensions/Extensions.mjs';
import { RenderTargetSystem } from '../../shared/renderTarget/RenderTargetSystem.mjs';
import { GpuRenderTargetAdaptor } from './GpuRenderTargetAdaptor.mjs';

"use strict";
class GpuRenderTargetSystem extends RenderTargetSystem {
  constructor(renderer) {
    super(renderer);
    this.adaptor = new GpuRenderTargetAdaptor();
    this.adaptor.init(renderer, this);
  }
}
/** @ignore */
GpuRenderTargetSystem.extension = {
  type: [ExtensionType.WebGPUSystem],
  name: "renderTarget"
};

export { GpuRenderTargetSystem };
//# sourceMappingURL=GpuRenderTargetSystem.mjs.map
