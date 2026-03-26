import { ExtensionType } from '../../../extensions/Extensions.mjs';

"use strict";
class GlEncoderSystem {
  constructor(renderer) {
    this.commandFinished = Promise.resolve();
    this._renderer = renderer;
  }
  setGeometry(geometry, shader) {
    this._renderer.geometry.bind(geometry, shader.glProgram);
  }
  finishRenderPass() {
  }
  draw(options) {
    const renderer = this._renderer;
    const { geometry, shader, state, skipSync, topology: type, size, start, instanceCount } = options;
    renderer.shader.bind(shader, skipSync);
    renderer.geometry.bind(geometry, renderer.shader._activeProgram);
    if (state) {
      renderer.state.set(state);
    }
    renderer.geometry.draw(type, size, start, instanceCount ?? geometry.instanceCount);
  }
  destroy() {
    this._renderer = null;
  }
}
/** @ignore */
GlEncoderSystem.extension = {
  type: [
    ExtensionType.WebGLSystem
  ],
  name: "encoder"
};

export { GlEncoderSystem };
//# sourceMappingURL=GlEncoderSystem.mjs.map
