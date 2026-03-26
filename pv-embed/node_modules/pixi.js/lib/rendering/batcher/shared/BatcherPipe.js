'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var State = require('../../renderers/shared/state/State.js');
var DefaultBatcher = require('./DefaultBatcher.js');

"use strict";
const _BatcherPipe = class _BatcherPipe {
  constructor(renderer, adaptor) {
    this.state = State.State.for2d();
    this._batchersByInstructionSet = /* @__PURE__ */ Object.create(null);
    /** A record of all active batchers, keyed by their names */
    this._activeBatches = /* @__PURE__ */ Object.create(null);
    this.renderer = renderer;
    this._adaptor = adaptor;
    this._adaptor.init?.(this);
  }
  static getBatcher(name) {
    return new this._availableBatchers[name]();
  }
  buildStart(instructionSet) {
    let batchers = this._batchersByInstructionSet[instructionSet.uid];
    if (!batchers) {
      batchers = this._batchersByInstructionSet[instructionSet.uid] = /* @__PURE__ */ Object.create(null);
      batchers.default || (batchers.default = new DefaultBatcher.DefaultBatcher({
        maxTextures: this.renderer.limits.maxBatchableTextures
      }));
    }
    this._activeBatches = batchers;
    this._activeBatch = this._activeBatches.default;
    for (const i in this._activeBatches) {
      this._activeBatches[i].begin();
    }
  }
  addToBatch(batchableObject, instructionSet) {
    if (this._activeBatch.name !== batchableObject.batcherName) {
      this._activeBatch.break(instructionSet);
      let batch = this._activeBatches[batchableObject.batcherName];
      if (!batch) {
        batch = this._activeBatches[batchableObject.batcherName] = _BatcherPipe.getBatcher(batchableObject.batcherName);
        batch.begin();
      }
      this._activeBatch = batch;
    }
    this._activeBatch.add(batchableObject);
  }
  break(instructionSet) {
    this._activeBatch.break(instructionSet);
  }
  buildEnd(instructionSet) {
    this._activeBatch.break(instructionSet);
    const batches = this._activeBatches;
    for (const i in batches) {
      const batch = batches[i];
      const geometry = batch.geometry;
      geometry.indexBuffer.setDataWithSize(batch.indexBuffer, batch.indexSize, true);
      geometry.buffers[0].setDataWithSize(batch.attributeBuffer.float32View, batch.attributeSize, false);
    }
  }
  upload(instructionSet) {
    const batchers = this._batchersByInstructionSet[instructionSet.uid];
    for (const i in batchers) {
      const batcher = batchers[i];
      const geometry = batcher.geometry;
      if (batcher.dirty) {
        batcher.dirty = false;
        geometry.buffers[0].update(batcher.attributeSize * 4);
      }
    }
  }
  execute(batch) {
    if (batch.action === "startBatch") {
      const batcher = batch.batcher;
      const geometry = batcher.geometry;
      const shader = batcher.shader;
      this._adaptor.start(this, geometry, shader);
    }
    this._adaptor.execute(this, batch);
  }
  destroy() {
    this.state = null;
    this.renderer = null;
    this._adaptor = null;
    for (const i in this._activeBatches) {
      this._activeBatches[i].destroy();
    }
    this._activeBatches = null;
  }
};
/** @ignore */
_BatcherPipe.extension = {
  type: [
    Extensions.ExtensionType.WebGLPipes,
    Extensions.ExtensionType.WebGPUPipes,
    Extensions.ExtensionType.CanvasPipes
  ],
  name: "batch"
};
_BatcherPipe._availableBatchers = /* @__PURE__ */ Object.create(null);
let BatcherPipe = _BatcherPipe;
Extensions.extensions.handleByMap(Extensions.ExtensionType.Batcher, BatcherPipe._availableBatchers);
Extensions.extensions.add(DefaultBatcher.DefaultBatcher);

exports.BatcherPipe = BatcherPipe;
//# sourceMappingURL=BatcherPipe.js.map
