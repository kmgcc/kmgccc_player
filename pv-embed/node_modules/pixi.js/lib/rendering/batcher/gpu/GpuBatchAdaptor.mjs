import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { State } from '../../renderers/shared/state/State.mjs';
import { getTextureBatchBindGroup } from './getTextureBatchBindGroup.mjs';

"use strict";
const tempState = State.for2d();
class GpuBatchAdaptor {
  start(batchPipe, geometry, shader) {
    const renderer = batchPipe.renderer;
    const encoder = renderer.encoder;
    const program = shader.gpuProgram;
    this._shader = shader;
    this._geometry = geometry;
    encoder.setGeometry(geometry, program);
    tempState.blendMode = "normal";
    renderer.pipeline.getPipeline(
      geometry,
      program,
      tempState
    );
    const globalUniformsBindGroup = renderer.globalUniforms.bindGroup;
    encoder.resetBindGroup(1);
    encoder.setBindGroup(0, globalUniformsBindGroup, program);
  }
  execute(batchPipe, batch) {
    const program = this._shader.gpuProgram;
    const renderer = batchPipe.renderer;
    const encoder = renderer.encoder;
    if (!batch.bindGroup) {
      const textureBatch = batch.textures;
      batch.bindGroup = getTextureBatchBindGroup(
        textureBatch.textures,
        textureBatch.count,
        renderer.limits.maxBatchableTextures
      );
    }
    tempState.blendMode = batch.blendMode;
    const gpuBindGroup = renderer.bindGroup.getBindGroup(
      batch.bindGroup,
      program,
      1
    );
    const pipeline = renderer.pipeline.getPipeline(
      this._geometry,
      program,
      tempState,
      batch.topology
    );
    batch.bindGroup._touch(renderer.gc.now, renderer.tick);
    encoder.setPipeline(pipeline);
    encoder.renderPassEncoder.setBindGroup(1, gpuBindGroup);
    encoder.renderPassEncoder.drawIndexed(batch.size, 1, batch.start);
  }
}
/** @ignore */
GpuBatchAdaptor.extension = {
  type: [
    ExtensionType.WebGPUPipesAdaptor
  ],
  name: "batch"
};

export { GpuBatchAdaptor };
//# sourceMappingURL=GpuBatchAdaptor.mjs.map
