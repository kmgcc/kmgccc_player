'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var Buffer = require('../shared/buffer/Buffer.js');
var BufferResource = require('../shared/buffer/BufferResource.js');
var _const = require('../shared/buffer/const.js');
var UboBatch = require('./buffer/UboBatch.js');
var BindGroup = require('./shader/BindGroup.js');

"use strict";
const minUniformOffsetAlignment = 128;
class GpuUniformBatchPipe {
  constructor(renderer) {
    this._bindGroupHash = /* @__PURE__ */ Object.create(null);
    // number of buffers..
    this._buffers = [];
    this._bindGroups = [];
    this._bufferResources = [];
    this._renderer = renderer;
    this._batchBuffer = new UboBatch.UboBatch({ minUniformOffsetAlignment });
    const totalBuffers = 256 / minUniformOffsetAlignment;
    for (let i = 0; i < totalBuffers; i++) {
      let usage = _const.BufferUsage.UNIFORM | _const.BufferUsage.COPY_DST;
      if (i === 0) usage |= _const.BufferUsage.COPY_SRC;
      this._buffers.push(new Buffer.Buffer({
        data: this._batchBuffer.data,
        usage
      }));
    }
  }
  renderEnd() {
    this._uploadBindGroups();
    this._resetBindGroups();
  }
  _resetBindGroups() {
    this._bindGroupHash = /* @__PURE__ */ Object.create(null);
    this._batchBuffer.clear();
  }
  // just works for single bind groups for now
  getUniformBindGroup(group, duplicate) {
    if (!duplicate && this._bindGroupHash[group.uid]) {
      return this._bindGroupHash[group.uid];
    }
    this._renderer.ubo.ensureUniformGroup(group);
    const data = group.buffer.data;
    const offset = this._batchBuffer.addEmptyGroup(data.length);
    this._renderer.ubo.syncUniformGroup(group, this._batchBuffer.data, offset / 4);
    this._bindGroupHash[group.uid] = this._getBindGroup(offset / minUniformOffsetAlignment);
    return this._bindGroupHash[group.uid];
  }
  getUboResource(group) {
    this._renderer.ubo.updateUniformGroup(group);
    const data = group.buffer.data;
    const offset = this._batchBuffer.addGroup(data);
    return this._getBufferResource(offset / minUniformOffsetAlignment);
  }
  getArrayBindGroup(data) {
    const offset = this._batchBuffer.addGroup(data);
    return this._getBindGroup(offset / minUniformOffsetAlignment);
  }
  getArrayBufferResource(data) {
    const offset = this._batchBuffer.addGroup(data);
    const index = offset / minUniformOffsetAlignment;
    return this._getBufferResource(index);
  }
  _getBufferResource(index) {
    if (!this._bufferResources[index]) {
      const buffer = this._buffers[index % 2];
      this._bufferResources[index] = new BufferResource.BufferResource({
        buffer,
        offset: (index / 2 | 0) * 256,
        size: minUniformOffsetAlignment
      });
    }
    return this._bufferResources[index];
  }
  _getBindGroup(index) {
    if (!this._bindGroups[index]) {
      const bindGroup = new BindGroup.BindGroup({
        0: this._getBufferResource(index)
      });
      this._bindGroups[index] = bindGroup;
    }
    return this._bindGroups[index];
  }
  _uploadBindGroups() {
    const bufferSystem = this._renderer.buffer;
    const firstBuffer = this._buffers[0];
    firstBuffer.update(this._batchBuffer.byteIndex);
    bufferSystem.updateBuffer(firstBuffer);
    const commandEncoder = this._renderer.gpu.device.createCommandEncoder();
    for (let i = 1; i < this._buffers.length; i++) {
      const buffer = this._buffers[i];
      commandEncoder.copyBufferToBuffer(
        bufferSystem.getGPUBuffer(firstBuffer),
        minUniformOffsetAlignment,
        bufferSystem.getGPUBuffer(buffer),
        0,
        this._batchBuffer.byteIndex
      );
    }
    this._renderer.gpu.device.queue.submit([commandEncoder.finish()]);
  }
  destroy() {
    for (let i = 0; i < this._bindGroups.length; i++) {
      this._bindGroups[i]?.destroy();
    }
    this._bindGroups = null;
    this._bindGroupHash = null;
    for (let i = 0; i < this._buffers.length; i++) {
      this._buffers[i].destroy();
    }
    this._buffers = null;
    for (let i = 0; i < this._bufferResources.length; i++) {
      this._bufferResources[i].destroy();
    }
    this._bufferResources = null;
    this._batchBuffer.destroy();
    this._renderer = null;
  }
}
/** @ignore */
GpuUniformBatchPipe.extension = {
  type: [
    Extensions.ExtensionType.WebGPUPipes
  ],
  name: "uniformBatch"
};

exports.GpuUniformBatchPipe = GpuUniformBatchPipe;
//# sourceMappingURL=GpuUniformBatchPipe.js.map
