'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var getTextureBatchBindGroup = require('../../../rendering/batcher/gpu/getTextureBatchBindGroup.js');
var DefaultBatcher = require('../../../rendering/batcher/shared/DefaultBatcher.js');
var InstructionSet = require('../../../rendering/renderers/shared/instructions/InstructionSet.js');
var GCManagedHash = require('../../../utils/data/GCManagedHash.js');
var deprecation = require('../../../utils/logging/deprecation.js');
var PoolGroup = require('../../../utils/pool/PoolGroup.js');
var buildContextBatches = require('./utils/buildContextBatches.js');

"use strict";
class GpuGraphicsContext {
  constructor() {
    this.batches = [];
    this.geometryData = {
      vertices: [],
      uvs: [],
      indices: []
    };
  }
  reset() {
    if (this.batches) {
      this.batches.forEach((batch) => {
        PoolGroup.BigPool.return(batch);
      });
    }
    if (this.graphicsData) {
      PoolGroup.BigPool.return(this.graphicsData);
    }
    this.isBatchable = false;
    this.context = null;
    this.batches.length = 0;
    this.geometryData.indices.length = 0;
    this.geometryData.vertices.length = 0;
    this.geometryData.uvs.length = 0;
    this.graphicsData = null;
  }
  destroy() {
    this.reset();
    this.batches = null;
    this.geometryData = null;
  }
}
class GraphicsContextRenderData {
  constructor() {
    this.instructions = new InstructionSet.InstructionSet();
  }
  init(options) {
    const maxTextures = options.maxTextures;
    this.batcher ? this.batcher._updateMaxTextures(maxTextures) : this.batcher = new DefaultBatcher.DefaultBatcher({ maxTextures });
    this.instructions.reset();
  }
  /**
   * @deprecated since version 8.0.0
   * Use `batcher.geometry` instead.
   * @see {Batcher#geometry}
   */
  get geometry() {
    deprecation.deprecation(deprecation.v8_3_4, "GraphicsContextRenderData#geometry is deprecated, please use batcher.geometry instead.");
    return this.batcher.geometry;
  }
  destroy() {
    this.batcher.destroy();
    this.instructions.destroy();
    this.batcher = null;
    this.instructions = null;
  }
}
const _GraphicsContextSystem = class _GraphicsContextSystem {
  constructor(renderer) {
    this._renderer = renderer;
    this._managedContexts = new GCManagedHash.GCManagedHash({ renderer, type: "resource", name: "graphicsContext" });
  }
  /**
   * Runner init called, update the default options
   * @ignore
   */
  init(options) {
    _GraphicsContextSystem.defaultOptions.bezierSmoothness = options?.bezierSmoothness ?? _GraphicsContextSystem.defaultOptions.bezierSmoothness;
  }
  /**
   * Returns the render data for a given GraphicsContext.
   * @param context - The GraphicsContext to get the render data for.
   * @internal
   */
  getContextRenderData(context) {
    return context._gpuData[this._renderer.uid].graphicsData || this._initContextRenderData(context);
  }
  /**
   * Updates the GPU context for a given GraphicsContext.
   * If the context is dirty, it will rebuild the batches and geometry data.
   * @param context - The GraphicsContext to update.
   * @returns The updated GpuGraphicsContext.
   * @internal
   */
  updateGpuContext(context) {
    const hasContext = !!context._gpuData[this._renderer.uid];
    const gpuContext = context._gpuData[this._renderer.uid] || this._initContext(context);
    if (context.dirty || !hasContext) {
      if (hasContext) {
        gpuContext.reset();
      }
      buildContextBatches.buildContextBatches(context, gpuContext);
      const batchMode = context.batchMode;
      if (context.customShader || batchMode === "no-batch") {
        gpuContext.isBatchable = false;
      } else if (batchMode === "auto") {
        gpuContext.isBatchable = gpuContext.geometryData.vertices.length < 400;
      } else {
        gpuContext.isBatchable = true;
      }
      context.dirty = false;
    }
    return gpuContext;
  }
  /**
   * Returns the GpuGraphicsContext for a given GraphicsContext.
   * If it does not exist, it will initialize a new one.
   * @param context - The GraphicsContext to get the GpuGraphicsContext for.
   * @returns The GpuGraphicsContext for the given GraphicsContext.
   * @internal
   */
  getGpuContext(context) {
    return context._gpuData[this._renderer.uid] || this._initContext(context);
  }
  _initContextRenderData(context) {
    const graphicsData = PoolGroup.BigPool.get(GraphicsContextRenderData, {
      maxTextures: this._renderer.limits.maxBatchableTextures
    });
    const gpuContext = context._gpuData[this._renderer.uid];
    const { batches, geometryData } = gpuContext;
    gpuContext.graphicsData = graphicsData;
    const vertexSize = geometryData.vertices.length;
    const indexSize = geometryData.indices.length;
    for (let i = 0; i < batches.length; i++) {
      batches[i].applyTransform = false;
    }
    const batcher = graphicsData.batcher;
    batcher.ensureAttributeBuffer(vertexSize);
    batcher.ensureIndexBuffer(indexSize);
    batcher.begin();
    for (let i = 0; i < batches.length; i++) {
      const batch = batches[i];
      batcher.add(batch);
    }
    batcher.finish(graphicsData.instructions);
    const geometry = batcher.geometry;
    geometry.indexBuffer.setDataWithSize(batcher.indexBuffer, batcher.indexSize, true);
    geometry.buffers[0].setDataWithSize(batcher.attributeBuffer.float32View, batcher.attributeSize, true);
    const drawBatches = batcher.batches;
    for (let i = 0; i < drawBatches.length; i++) {
      const batch = drawBatches[i];
      batch.bindGroup = getTextureBatchBindGroup.getTextureBatchBindGroup(
        batch.textures.textures,
        batch.textures.count,
        this._renderer.limits.maxBatchableTextures
      );
    }
    return graphicsData;
  }
  _initContext(context) {
    const gpuContext = new GpuGraphicsContext();
    gpuContext.context = context;
    context._gpuData[this._renderer.uid] = gpuContext;
    this._managedContexts.add(context);
    return gpuContext;
  }
  destroy() {
    this._managedContexts.destroy();
    this._renderer = null;
  }
};
/** @ignore */
_GraphicsContextSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem,
    Extensions.ExtensionType.WebGPUSystem
  ],
  name: "graphicsContext"
};
/** The default options for the GraphicsContextSystem. */
_GraphicsContextSystem.defaultOptions = {
  /**
   * A value from 0 to 1 that controls the smoothness of bezier curves (the higher the smoother)
   * @default 0.5
   */
  bezierSmoothness: 0.5
};
let GraphicsContextSystem = _GraphicsContextSystem;

exports.GpuGraphicsContext = GpuGraphicsContext;
exports.GraphicsContextRenderData = GraphicsContextRenderData;
exports.GraphicsContextSystem = GraphicsContextSystem;
//# sourceMappingURL=GraphicsContextSystem.js.map
