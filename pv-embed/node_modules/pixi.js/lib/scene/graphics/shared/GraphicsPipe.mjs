import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { State } from '../../../rendering/renderers/shared/state/State.mjs';
import { GCManagedHash } from '../../../utils/data/GCManagedHash.mjs';
import { BigPool } from '../../../utils/pool/PoolGroup.mjs';
import { color32BitToUniform } from '../gpu/colorToUniform.mjs';
import { BatchableGraphics } from './BatchableGraphics.mjs';

"use strict";
class GraphicsGpuData {
  constructor() {
    this.batches = [];
    this.batched = false;
  }
  destroy() {
    this.batches.forEach((batch) => {
      BigPool.return(batch);
    });
    this.batches.length = 0;
  }
}
class GraphicsPipe {
  constructor(renderer, adaptor) {
    this.state = State.for2d();
    this.renderer = renderer;
    this._adaptor = adaptor;
    this.renderer.runners.contextChange.add(this);
    this._managedGraphics = new GCManagedHash({ renderer, type: "renderable", priority: -1, name: "graphics" });
  }
  contextChange() {
    this._adaptor.contextChange(this.renderer);
  }
  validateRenderable(graphics) {
    const context = graphics.context;
    const wasBatched = !!graphics._gpuData;
    const contextSystem = this.renderer.graphicsContext;
    const gpuContext = contextSystem.updateGpuContext(context);
    if (gpuContext.isBatchable || wasBatched !== gpuContext.isBatchable) {
      return true;
    }
    return false;
  }
  addRenderable(graphics, instructionSet) {
    const contextSystem = this.renderer.graphicsContext;
    const gpuContext = contextSystem.updateGpuContext(graphics.context);
    if (graphics.didViewUpdate) {
      this._rebuild(graphics);
    }
    if (gpuContext.isBatchable) {
      this._addToBatcher(graphics, instructionSet);
    } else {
      this.renderer.renderPipes.batch.break(instructionSet);
      instructionSet.add(graphics);
    }
  }
  updateRenderable(graphics) {
    const gpuData = this._getGpuDataForRenderable(graphics);
    const batches = gpuData.batches;
    for (let i = 0; i < batches.length; i++) {
      const batch = batches[i];
      batch._batcher.updateElement(batch);
    }
  }
  execute(graphics) {
    if (!graphics.isRenderable) return;
    const renderer = this.renderer;
    const context = graphics.context;
    const contextSystem = renderer.graphicsContext;
    if (!contextSystem.getGpuContext(context).batches.length) {
      return;
    }
    const shader = context.customShader || this._adaptor.shader;
    this.state.blendMode = graphics.groupBlendMode;
    const localUniforms = shader.resources.localUniforms.uniforms;
    localUniforms.uTransformMatrix = graphics.groupTransform;
    localUniforms.uRound = renderer._roundPixels | graphics._roundPixels;
    color32BitToUniform(
      graphics.groupColorAlpha,
      localUniforms.uColor,
      0
    );
    this._adaptor.execute(this, graphics);
  }
  _rebuild(graphics) {
    const gpuData = this._getGpuDataForRenderable(graphics);
    const contextSystem = this.renderer.graphicsContext;
    const gpuContext = contextSystem.updateGpuContext(graphics.context);
    gpuData.destroy();
    if (gpuContext.isBatchable) {
      this._updateBatchesForRenderable(graphics, gpuData);
    }
  }
  _addToBatcher(graphics, instructionSet) {
    const batchPipe = this.renderer.renderPipes.batch;
    const batches = this._getGpuDataForRenderable(graphics).batches;
    for (let i = 0; i < batches.length; i++) {
      const batch = batches[i];
      batchPipe.addToBatch(batch, instructionSet);
    }
  }
  _getGpuDataForRenderable(graphics) {
    return graphics._gpuData[this.renderer.uid] || this._initGpuDataForRenderable(graphics);
  }
  _initGpuDataForRenderable(graphics) {
    const gpuData = new GraphicsGpuData();
    graphics._gpuData[this.renderer.uid] = gpuData;
    this._managedGraphics.add(graphics);
    return gpuData;
  }
  _updateBatchesForRenderable(graphics, gpuData) {
    const context = graphics.context;
    const contextSystem = this.renderer.graphicsContext;
    const gpuContext = contextSystem.getGpuContext(context);
    const roundPixels = this.renderer._roundPixels | graphics._roundPixels;
    gpuData.batches = gpuContext.batches.map((batch) => {
      const batchClone = BigPool.get(BatchableGraphics);
      batch.copyTo(batchClone);
      batchClone.renderable = graphics;
      batchClone.roundPixels = roundPixels;
      return batchClone;
    });
  }
  destroy() {
    this._managedGraphics.destroy();
    this.renderer = null;
    this._adaptor.destroy();
    this._adaptor = null;
    this.state = null;
  }
}
/** @ignore */
GraphicsPipe.extension = {
  type: [
    ExtensionType.WebGLPipes,
    ExtensionType.WebGPUPipes
  ],
  name: "graphics"
};

export { GraphicsGpuData, GraphicsPipe };
//# sourceMappingURL=GraphicsPipe.mjs.map
