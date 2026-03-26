'use strict';

var Extensions = require('../../../../extensions/Extensions.js');
var GCManagedHash = require('../../../../utils/data/GCManagedHash.js');
var uid = require('../../../../utils/data/uid.js');
var fastCopy = require('../../shared/buffer/utils/fastCopy.js');

"use strict";
class GpuBufferData {
  constructor(gpuBuffer) {
    this.gpuBuffer = gpuBuffer;
  }
  destroy() {
    this.gpuBuffer.destroy();
    this.gpuBuffer = null;
  }
}
class GpuBufferSystem {
  constructor(renderer) {
    this._renderer = renderer;
    this._managedBuffers = new GCManagedHash.GCManagedHash({
      renderer,
      type: "resource",
      onUnload: this.onBufferUnload.bind(this),
      name: "gpuBuffer"
    });
  }
  contextChange(gpu) {
    this._gpu = gpu;
  }
  getGPUBuffer(buffer) {
    buffer._gcLastUsed = this._renderer.gc.now;
    return buffer._gpuData[this._renderer.uid]?.gpuBuffer || this.createGPUBuffer(buffer);
  }
  updateBuffer(buffer) {
    const gpuBuffer = this.getGPUBuffer(buffer);
    const data = buffer.data;
    if (buffer._updateID && data) {
      buffer._updateID = 0;
      this._gpu.device.queue.writeBuffer(
        gpuBuffer,
        0,
        data.buffer,
        0,
        // round to the nearest 4 bytes
        (buffer._updateSize || data.byteLength) + 3 & ~3
      );
    }
    return gpuBuffer;
  }
  /** dispose all WebGL resources of all managed buffers */
  destroyAll() {
    this._managedBuffers.removeAll();
  }
  onBufferUnload(buffer) {
    buffer.off("update", this.updateBuffer, this);
    buffer.off("change", this.onBufferChange, this);
  }
  createGPUBuffer(buffer) {
    const gpuBuffer = this._gpu.device.createBuffer(buffer.descriptor);
    buffer._updateID = 0;
    buffer._resourceId = uid.uid("resource");
    if (buffer.data) {
      fastCopy.fastCopy(
        buffer.data.buffer,
        gpuBuffer.getMappedRange(),
        buffer.data.byteOffset,
        buffer.data.byteLength
      );
      gpuBuffer.unmap();
    }
    buffer._gpuData[this._renderer.uid] = new GpuBufferData(gpuBuffer);
    if (this._managedBuffers.add(buffer)) {
      buffer.on("update", this.updateBuffer, this);
      buffer.on("change", this.onBufferChange, this);
    }
    return gpuBuffer;
  }
  onBufferChange(buffer) {
    this._managedBuffers.remove(buffer);
    buffer._updateID = 0;
    this.createGPUBuffer(buffer);
  }
  destroy() {
    this._managedBuffers.destroy();
    this._renderer = null;
    this._gpu = null;
  }
}
/** @ignore */
GpuBufferSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGPUSystem
  ],
  name: "buffer"
};

exports.GpuBufferData = GpuBufferData;
exports.GpuBufferSystem = GpuBufferSystem;
//# sourceMappingURL=GpuBufferSystem.js.map
