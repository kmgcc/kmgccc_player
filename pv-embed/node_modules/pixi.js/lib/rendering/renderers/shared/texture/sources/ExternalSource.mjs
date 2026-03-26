import { GlTexture } from '../../../gl/texture/GlTexture.mjs';
import { GPUTextureGpuData } from '../../../gpu/texture/GpuTextureSystem.mjs';
import { RendererType } from '../../../types.mjs';
import { TextureSource } from './TextureSource.mjs';

"use strict";
const placeholderGl = /* @__PURE__ */ Object.create(null);
const placeholderGpu = /* @__PURE__ */ Object.create(null);
function getPlaceholder(renderer) {
  var _a;
  if (renderer.type === RendererType.WEBGPU) {
    placeholderGpu[_a = renderer.uid] || (placeholderGpu[_a] = renderer.gpu.device.createTexture({
      label: "ExternalSource placeholder",
      size: { width: 1, height: 1 },
      format: "rgba8unorm",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST
    }));
    return placeholderGpu[renderer.uid];
  }
  if (!placeholderGl[renderer.uid]) {
    const gl = renderer.gl;
    const texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    placeholderGl[renderer.uid] = texture;
  }
  return placeholderGl[renderer.uid];
}
class ExternalSource extends TextureSource {
  constructor({ resource, renderer, label, width, height }) {
    resource || (resource = getPlaceholder(renderer));
    width || (width = width ?? resource?.width ?? 1);
    height || (height = height ?? resource?.height ?? 1);
    super({
      resource,
      width,
      height,
      label,
      // External textures shouldn't be garbage collected - the external library owns them
      autoGarbageCollect: false
    });
    this._renderer = renderer;
    this._initGpuData(resource);
  }
  /**
   * Test if a resource is a valid external GPU texture.
   * @param resource - The resource to test
   * @returns True if the resource is a GPUTexture or WebGLTexture
   */
  static test(resource) {
    return globalThis.GPUTexture && resource instanceof GPUTexture || globalThis.WebGLTexture && resource instanceof WebGLTexture;
  }
  _validateTexture(resource) {
    const renderer = this._renderer;
    const isWebGPU = !!renderer.gpu;
    const isGPUTexture = globalThis.GPUTexture && resource instanceof GPUTexture;
    const isWebGLTexture = globalThis.WebGLTexture && resource instanceof WebGLTexture;
    if (isWebGPU && isWebGLTexture) {
      throw new Error("Cannot use WebGLTexture with a WebGPU renderer");
    }
    if (!isWebGPU && isGPUTexture) {
      throw new Error("Cannot use GPUTexture with a WebGL renderer");
    }
    if (!isWebGPU) {
      const gl = renderer.gl;
      if (gl && !gl.isTexture(resource)) {
        throw new Error("WebGLTexture does not belong to this renderer's WebGL context");
      }
    }
  }
  _initGpuData(resource) {
    const renderer = this._renderer;
    this._validateTexture(resource);
    if (renderer.gpu) {
      this._gpuData[renderer.uid] = new GPUTextureGpuData(resource);
    } else {
      this._gpuData[renderer.uid] = new GlTexture(resource);
    }
  }
  /**
   * Update the external GPU texture reference.
   * Call this when the external library provides a new texture.
   * @param gpuTexture - The new GPU texture
   * @param width - New width (required for WebGLTexture, auto-detected for GPUTexture)
   * @param height - New height (required for WebGLTexture, auto-detected for GPUTexture)
   */
  updateGPUTexture(gpuTexture, width, height) {
    const renderer = this._renderer;
    const gpuData = this._gpuData[renderer.uid];
    this.resource = gpuTexture;
    if (renderer.gpu) {
      this._validateTexture(gpuTexture);
      const data = gpuData;
      if (data.gpuTexture !== gpuTexture) {
        data.gpuTexture = gpuTexture;
        data.textureView = null;
        const textureSystem = renderer.texture;
        if (textureSystem?._bindGroupHash) {
          textureSystem._bindGroupHash[this.uid] = null;
        }
      }
      const newWidth = width ?? gpuTexture.width;
      const newHeight = height ?? gpuTexture.height;
      this.resize(newWidth, newHeight);
    } else {
      this._validateTexture(gpuTexture);
      const data = gpuData;
      data.texture = gpuTexture;
      if (width !== void 0 && height !== void 0) {
        this.resize(width, height);
      }
    }
    this.emit("update", this);
  }
  destroy() {
    const renderer = this._renderer;
    delete this._gpuData[renderer.uid];
    super.destroy();
  }
}

export { ExternalSource };
//# sourceMappingURL=ExternalSource.mjs.map
