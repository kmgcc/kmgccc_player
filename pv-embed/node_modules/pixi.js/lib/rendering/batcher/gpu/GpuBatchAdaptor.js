'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var State = require('../../renderers/shared/state/State.js');
var getTextureBatchBindGroup = require('./getTextureBatchBindGroup.js');

"use strict";
const tempState = State.State.for2d();
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
      batch.bindGroup = getTextureBatchBindGroup.getTextureBatchBindGroup(
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
    Extensions.ExtensionType.WebGPUPipesAdaptor
  ],
  name: "batch"
};

exports.GpuBatchAdaptor = GpuBatchAdaptor;
//# sourceMappingURL=GpuBatchAdaptor.js.map
