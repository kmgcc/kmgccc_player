import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { State } from '../../renderers/shared/state/State.mjs';

"use strict";
class GlBatchAdaptor {
  constructor() {
    this._tempState = State.for2d();
    /**
     * We only want to sync the a batched shaders uniforms once on first use
     * this is a hash of shader uids to a boolean value.  When the shader is first bound
     * we set the value to true.  When the shader is bound again we check the value and
     * if it is true we know that the uniforms have already been synced and we skip it.
     */
    this._didUploadHash = {};
  }
  init(batcherPipe) {
    batcherPipe.renderer.runners.contextChange.add(this);
  }
  contextChange() {
    this._didUploadHash = {};
  }
  start(batchPipe, geometry, shader) {
    const renderer = batchPipe.renderer;
    const didUpload = this._didUploadHash[shader.uid];
    renderer.shader.bind(shader, didUpload);
    if (!didUpload) {
      this._didUploadHash[shader.uid] = true;
    }
    renderer.shader.updateUniformGroup(renderer.globalUniforms.uniformGroup);
    renderer.geometry.bind(geometry, shader.glProgram);
  }
  execute(batchPipe, batch) {
    const renderer = batchPipe.renderer;
    this._tempState.blendMode = batch.blendMode;
    renderer.state.set(this._tempState);
    const textures = batch.textures.textures;
    for (let i = 0; i < batch.textures.count; i++) {
      renderer.texture.bind(textures[i], i);
    }
    renderer.geometry.draw(batch.topology, batch.size, batch.start);
  }
}
/** @ignore */
GlBatchAdaptor.extension = {
  type: [
    ExtensionType.WebGLPipesAdaptor
  ],
  name: "batch"
};

export { GlBatchAdaptor };
//# sourceMappingURL=GlBatchAdaptor.mjs.map
