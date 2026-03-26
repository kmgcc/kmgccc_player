import { ExtensionType } from '../../../extensions/Extensions.mjs';

"use strict";
class BindGroupSystem {
  constructor(renderer) {
    this._hash = /* @__PURE__ */ Object.create(null);
    this._renderer = renderer;
  }
  contextChange(gpu) {
    this._gpu = gpu;
  }
  getBindGroup(bindGroup, program, groupIndex) {
    bindGroup._updateKey();
    const gpuBindGroup = this._hash[bindGroup._key] || this._createBindGroup(bindGroup, program, groupIndex);
    return gpuBindGroup;
  }
  _createBindGroup(group, program, groupIndex) {
    const device = this._gpu.device;
    const groupLayout = program.layout[groupIndex];
    const entries = [];
    const renderer = this._renderer;
    for (const j in groupLayout) {
      const resource = group.resources[j] ?? group.resources[groupLayout[j]];
      let gpuResource;
      if (resource._resourceType === "uniformGroup") {
        const uniformGroup = resource;
        renderer.ubo.updateUniformGroup(uniformGroup);
        const buffer = uniformGroup.buffer;
        gpuResource = {
          buffer: renderer.buffer.getGPUBuffer(buffer),
          offset: 0,
          size: buffer.descriptor.size
        };
      } else if (resource._resourceType === "buffer") {
        const buffer = resource;
        gpuResource = {
          buffer: renderer.buffer.getGPUBuffer(buffer),
          offset: 0,
          size: buffer.descriptor.size
        };
      } else if (resource._resourceType === "bufferResource") {
        const bufferResource = resource;
        gpuResource = {
          buffer: renderer.buffer.getGPUBuffer(bufferResource.buffer),
          offset: bufferResource.offset,
          size: bufferResource.size
        };
      } else if (resource._resourceType === "textureSampler") {
        const sampler = resource;
        gpuResource = renderer.texture.getGpuSampler(sampler);
      } else if (resource._resourceType === "textureSource") {
        const texture = resource;
        gpuResource = renderer.texture.getTextureView(texture);
      }
      entries.push({
        binding: groupLayout[j],
        resource: gpuResource
      });
    }
    const layout = renderer.shader.getProgramData(program).bindGroups[groupIndex];
    const gpuBindGroup = device.createBindGroup({
      layout,
      entries
    });
    this._hash[group._key] = gpuBindGroup;
    return gpuBindGroup;
  }
  destroy() {
    this._hash = null;
    this._renderer = null;
  }
}
/** @ignore */
BindGroupSystem.extension = {
  type: [
    ExtensionType.WebGPUSystem
  ],
  name: "bindGroup"
};

export { BindGroupSystem };
//# sourceMappingURL=BindGroupSystem.mjs.map
