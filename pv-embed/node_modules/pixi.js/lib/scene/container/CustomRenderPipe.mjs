import { ExtensionType } from '../../extensions/Extensions.mjs';

"use strict";
class CustomRenderPipe {
  constructor(renderer) {
    this._renderer = renderer;
  }
  updateRenderable() {
  }
  destroyRenderable() {
  }
  validateRenderable() {
    return false;
  }
  addRenderable(container, instructionSet) {
    this._renderer.renderPipes.batch.break(instructionSet);
    instructionSet.add(container);
  }
  execute(container) {
    if (!container.isRenderable) return;
    container.render(this._renderer);
  }
  destroy() {
    this._renderer = null;
  }
}
CustomRenderPipe.extension = {
  type: [
    ExtensionType.WebGLPipes,
    ExtensionType.WebGPUPipes,
    ExtensionType.CanvasPipes
  ],
  name: "customRender"
};

export { CustomRenderPipe };
//# sourceMappingURL=CustomRenderPipe.mjs.map
