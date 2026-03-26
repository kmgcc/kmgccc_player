'use strict';

var Extensions = require('../../../extensions/Extensions.js');

"use strict";
class GpuEncoderSystem {
  constructor(renderer) {
    this._boundBindGroup = /* @__PURE__ */ Object.create(null);
    this._boundVertexBuffer = /* @__PURE__ */ Object.create(null);
    this._renderer = renderer;
  }
  renderStart() {
    this.commandFinished = new Promise((resolve) => {
      this._resolveCommandFinished = resolve;
    });
    this.commandEncoder = this._renderer.gpu.device.createCommandEncoder();
  }
  beginRenderPass(gpuRenderTarget) {
    this.endRenderPass();
    this._clearCache();
    this.renderPassEncoder = this.commandEncoder.beginRenderPass(gpuRenderTarget.descriptor);
  }
  endRenderPass() {
    if (this.renderPassEncoder) {
      this.renderPassEncoder.end();
    }
    this.renderPassEncoder = null;
  }
  setViewport(viewport) {
    this.renderPassEncoder.setViewport(viewport.x, viewport.y, viewport.width, viewport.height, 0, 1);
  }
  setPipelineFromGeometryProgramAndState(geometry, program, state, topology) {
    const pipeline = this._renderer.pipeline.getPipeline(geometry, program, state, topology);
    this.setPipeline(pipeline);
  }
  setPipeline(pipeline) {
    if (this._boundPipeline === pipeline) return;
    this._boundPipeline = pipeline;
    this.renderPassEncoder.setPipeline(pipeline);
  }
  _setVertexBuffer(index, buffer) {
    if (this._boundVertexBuffer[index] === buffer) return;
    this._boundVertexBuffer[index] = buffer;
    this.renderPassEncoder.setVertexBuffer(index, this._renderer.buffer.updateBuffer(buffer));
  }
  _setIndexBuffer(buffer) {
    if (this._boundIndexBuffer === buffer) return;
    this._boundIndexBuffer = buffer;
    const indexFormat = buffer.data.BYTES_PER_ELEMENT === 2 ? "uint16" : "uint32";
    this.renderPassEncoder.setIndexBuffer(this._renderer.buffer.updateBuffer(buffer), indexFormat);
  }
  resetBindGroup(index) {
    this._boundBindGroup[index] = null;
  }
  setBindGroup(index, bindGroup, program) {
    if (this._boundBindGroup[index] === bindGroup) return;
    this._boundBindGroup[index] = bindGroup;
    bindGroup._touch(this._renderer.gc.now, this._renderer.tick);
    const gpuBindGroup = this._renderer.bindGroup.getBindGroup(bindGroup, program, index);
    this.renderPassEncoder.setBindGroup(index, gpuBindGroup);
  }
  setGeometry(geometry, program) {
    const buffersToBind = this._renderer.pipeline.getBufferNamesToBind(geometry, program);
    for (const i in buffersToBind) {
      this._setVertexBuffer(parseInt(i, 10), geometry.attributes[buffersToBind[i]].buffer);
    }
    if (geometry.indexBuffer) {
      this._setIndexBuffer(geometry.indexBuffer);
    }
  }
  _setShaderBindGroups(shader, skipSync) {
    for (const i in shader.groups) {
      const bindGroup = shader.groups[i];
      if (!skipSync) {
        this._syncBindGroup(bindGroup);
      }
      this.setBindGroup(i, bindGroup, shader.gpuProgram);
    }
  }
  _syncBindGroup(bindGroup) {
    for (const j in bindGroup.resources) {
      const resource = bindGroup.resources[j];
      if (resource.isUniformGroup) {
        this._renderer.ubo.updateUniformGroup(resource);
      }
    }
  }
  draw(options) {
    const { geometry, shader, state, topology, size, start, instanceCount, skipSync } = options;
    this.setPipelineFromGeometryProgramAndState(geometry, shader.gpuProgram, state, topology);
    this.setGeometry(geometry, shader.gpuProgram);
    this._setShaderBindGroups(shader, skipSync);
    if (geometry.indexBuffer) {
      this.renderPassEncoder.drawIndexed(
        size || geometry.indexBuffer.data.length,
        instanceCount ?? geometry.instanceCount,
        start || 0
      );
    } else {
      this.renderPassEncoder.draw(size || geometry.getSize(), instanceCount ?? geometry.instanceCount, start || 0);
    }
  }
  finishRenderPass() {
    if (this.renderPassEncoder) {
      this.renderPassEncoder.end();
      this.renderPassEncoder = null;
    }
  }
  postrender() {
    this.finishRenderPass();
    this._gpu.device.queue.submit([this.commandEncoder.finish()]);
    this._resolveCommandFinished();
    this.commandEncoder = null;
  }
  // restores a render pass if finishRenderPass was called
  // not optimised as really used for debugging!
  // used when we want to stop drawing and log a texture..
  restoreRenderPass() {
    const descriptor = this._renderer.renderTarget.adaptor.getDescriptor(
      this._renderer.renderTarget.renderTarget,
      false,
      [0, 0, 0, 1],
      this._renderer.renderTarget.mipLevel,
      this._renderer.renderTarget.layer
    );
    this.renderPassEncoder = this.commandEncoder.beginRenderPass(descriptor);
    const boundPipeline = this._boundPipeline;
    const boundVertexBuffer = { ...this._boundVertexBuffer };
    const boundIndexBuffer = this._boundIndexBuffer;
    const boundBindGroup = { ...this._boundBindGroup };
    this._clearCache();
    const viewport = this._renderer.renderTarget.viewport;
    this.renderPassEncoder.setViewport(viewport.x, viewport.y, viewport.width, viewport.height, 0, 1);
    this.setPipeline(boundPipeline);
    for (const i in boundVertexBuffer) {
      this._setVertexBuffer(i, boundVertexBuffer[i]);
    }
    for (const i in boundBindGroup) {
      this.setBindGroup(i, boundBindGroup[i], null);
    }
    this._setIndexBuffer(boundIndexBuffer);
  }
  _clearCache() {
    for (let i = 0; i < 16; i++) {
      this._boundBindGroup[i] = null;
      this._boundVertexBuffer[i] = null;
    }
    this._boundIndexBuffer = null;
    this._boundPipeline = null;
  }
  destroy() {
    this._renderer = null;
    this._gpu = null;
    this._boundBindGroup = null;
    this._boundVertexBuffer = null;
    this._boundIndexBuffer = null;
    this._boundPipeline = null;
  }
  contextChange(gpu) {
    this._gpu = gpu;
  }
}
/** @ignore */
GpuEncoderSystem.extension = {
  type: [Extensions.ExtensionType.WebGPUSystem],
  name: "encoder",
  priority: 1
};

exports.GpuEncoderSystem = GpuEncoderSystem;
//# sourceMappingURL=GpuEncoderSystem.js.map
