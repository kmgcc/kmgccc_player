'use strict';

var Extensions = require('../../extensions/Extensions.js');

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
    Extensions.ExtensionType.WebGLPipes,
    Extensions.ExtensionType.WebGPUPipes,
    Extensions.ExtensionType.CanvasPipes
  ],
  name: "customRender"
};

exports.CustomRenderPipe = CustomRenderPipe;
//# sourceMappingURL=CustomRenderPipe.js.map
