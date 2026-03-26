import { DOMAdapter } from '../../../../environment/adapter.mjs';
import { ExtensionType } from '../../../../extensions/Extensions.mjs';
import { GCManagedHash } from '../../../../utils/data/GCManagedHash.mjs';
import { UniformGroup } from '../../shared/shader/UniformGroup.mjs';
import { CanvasPool } from '../../shared/texture/CanvasPool.mjs';
import { BindGroup } from '../shader/BindGroup.mjs';
import { gpuUploadBufferImageResource } from './uploaders/gpuUploadBufferImageResource.mjs';
import { gpuUploadCompressedTextureResource, blockDataMap } from './uploaders/gpuUploadCompressedTextureResource.mjs';
import { createGpuUploadCubeTextureResource } from './uploaders/gpuUploadCubeTextureResource.mjs';
import { gpuUploadImageResource } from './uploaders/gpuUploadImageSource.mjs';
import { gpuUploadVideoResource } from './uploaders/gpuUploadVideoSource.mjs';
import { GpuMipmapGenerator } from './utils/GpuMipmapGenerator.mjs';

"use strict";
class GPUTextureGpuData {
  constructor(gpuTexture) {
    this.textureView = null;
    this.gpuTexture = gpuTexture;
  }
  /** Destroys this GPU data instance. */
  destroy() {
    this.gpuTexture.destroy();
    this.textureView = null;
    this.gpuTexture = null;
  }
}
class GpuTextureSystem {
  constructor(renderer) {
    this._gpuSamplers = /* @__PURE__ */ Object.create(null);
    this._bindGroupHash = /* @__PURE__ */ Object.create(null);
    this._renderer = renderer;
    renderer.gc.addCollection(this, "_bindGroupHash", "hash");
    this._managedTextures = new GCManagedHash({
      renderer,
      type: "resource",
      onUnload: this.onSourceUnload.bind(this),
      name: "gpuTextureSource"
    });
    const baseUploaders = {
      image: gpuUploadImageResource,
      buffer: gpuUploadBufferImageResource,
      video: gpuUploadVideoResource,
      compressed: gpuUploadCompressedTextureResource
    };
    this._uploads = {
      ...baseUploaders,
      cube: createGpuUploadCubeTextureResource(baseUploaders)
    };
  }
  /**
   * @deprecated since 8.15.0
   */
  get managedTextures() {
    return Object.values(this._managedTextures.items);
  }
  contextChange(gpu) {
    this._gpu = gpu;
  }
  /**
   * Initializes a texture source, if it has already been initialized nothing will happen.
   * @param source - The texture source to initialize.
   * @returns The initialized texture source.
   */
  initSource(source) {
    return source._gpuData[this._renderer.uid]?.gpuTexture || this._initSource(source);
  }
  _initSource(source) {
    if (source.autoGenerateMipmaps) {
      const biggestDimension = Math.max(source.pixelWidth, source.pixelHeight);
      source.mipLevelCount = Math.floor(Math.log2(biggestDimension)) + 1;
    }
    let usage = GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST;
    if (source.uploadMethodId !== "compressed") {
      usage |= GPUTextureUsage.RENDER_ATTACHMENT;
      usage |= GPUTextureUsage.COPY_SRC;
    }
    const blockData = blockDataMap[source.format] || { blockBytes: 4, blockWidth: 1, blockHeight: 1 };
    const width = Math.ceil(source.pixelWidth / blockData.blockWidth) * blockData.blockWidth;
    const height = Math.ceil(source.pixelHeight / blockData.blockHeight) * blockData.blockHeight;
    const textureDescriptor = {
      label: source.label,
      size: { width, height, depthOrArrayLayers: source.arrayLayerCount },
      format: source.format,
      sampleCount: source.sampleCount,
      mipLevelCount: source.mipLevelCount,
      dimension: source.dimension,
      usage
    };
    const gpuTexture = this._gpu.device.createTexture(textureDescriptor);
    source._gpuData[this._renderer.uid] = new GPUTextureGpuData(gpuTexture);
    const added = this._managedTextures.add(source);
    if (added) {
      source.on("update", this.onSourceUpdate, this);
      source.on("resize", this.onSourceResize, this);
      source.on("updateMipmaps", this.onUpdateMipmaps, this);
    }
    this.onSourceUpdate(source);
    return gpuTexture;
  }
  onSourceUpdate(source) {
    const gpuTexture = this.getGpuSource(source);
    if (!gpuTexture) return;
    if (this._uploads[source.uploadMethodId]) {
      this._uploads[source.uploadMethodId].upload(source, gpuTexture, this._gpu);
    }
    if (source.autoGenerateMipmaps && source.mipLevelCount > 1) {
      this.onUpdateMipmaps(source);
    }
  }
  onUpdateMipmaps(source) {
    if (!this._mipmapGenerator) {
      this._mipmapGenerator = new GpuMipmapGenerator(this._gpu.device);
    }
    const gpuTexture = this.getGpuSource(source);
    this._mipmapGenerator.generateMipmap(gpuTexture);
  }
  onSourceUnload(source) {
    source.off("update", this.onSourceUpdate, this);
    source.off("resize", this.onSourceResize, this);
    source.off("updateMipmaps", this.onUpdateMipmaps, this);
  }
  onSourceResize(source) {
    source._gcLastUsed = this._renderer.gc.now;
    const gpuData = source._gpuData[this._renderer.uid];
    const gpuTexture = gpuData?.gpuTexture;
    if (!gpuTexture) {
      this.initSource(source);
    } else if (gpuTexture.width !== source.pixelWidth || gpuTexture.height !== source.pixelHeight) {
      gpuData.destroy();
      this._bindGroupHash[source.uid] = null;
      source._gpuData[this._renderer.uid] = null;
      this.initSource(source);
    }
  }
  _initSampler(sampler) {
    this._gpuSamplers[sampler._resourceId] = this._gpu.device.createSampler(sampler);
    return this._gpuSamplers[sampler._resourceId];
  }
  getGpuSampler(sampler) {
    return this._gpuSamplers[sampler._resourceId] || this._initSampler(sampler);
  }
  getGpuSource(source) {
    source._gcLastUsed = this._renderer.gc.now;
    return source._gpuData[this._renderer.uid]?.gpuTexture || this.initSource(source);
  }
  /**
   * this returns s bind group for a specific texture, the bind group contains
   * - the texture source
   * - the texture style
   * - the texture matrix
   * This is cached so the bind group should only be created once per texture
   * @param texture - the texture you want the bindgroup for
   * @returns the bind group for the texture
   */
  getTextureBindGroup(texture) {
    return this._bindGroupHash[texture.uid] || this._createTextureBindGroup(texture);
  }
  _createTextureBindGroup(texture) {
    const source = texture.source;
    this._bindGroupHash[texture.uid] = new BindGroup({
      0: source,
      1: source.style,
      2: new UniformGroup({
        uTextureMatrix: { type: "mat3x3<f32>", value: texture.textureMatrix.mapCoord }
      })
    });
    return this._bindGroupHash[texture.uid];
  }
  getTextureView(texture) {
    const source = texture.source;
    source._gcLastUsed = this._renderer.gc.now;
    let gpuData = source._gpuData[this._renderer.uid];
    if (!gpuData) {
      this.initSource(source);
      gpuData = source._gpuData[this._renderer.uid];
    }
    gpuData.textureView || (gpuData.textureView = gpuData.gpuTexture.createView({ dimension: source.viewDimension }));
    return gpuData.textureView;
  }
  generateCanvas(texture) {
    const renderer = this._renderer;
    const commandEncoder = renderer.gpu.device.createCommandEncoder();
    const canvas = DOMAdapter.get().createCanvas();
    canvas.width = texture.source.pixelWidth;
    canvas.height = texture.source.pixelHeight;
    const context = canvas.getContext("webgpu");
    context.configure({
      device: renderer.gpu.device,
      usage: GPUTextureUsage.COPY_DST | GPUTextureUsage.COPY_SRC,
      format: DOMAdapter.get().getNavigator().gpu.getPreferredCanvasFormat(),
      alphaMode: "premultiplied"
    });
    commandEncoder.copyTextureToTexture({
      texture: renderer.texture.getGpuSource(texture.source),
      origin: {
        x: 0,
        y: 0
      }
    }, {
      texture: context.getCurrentTexture()
    }, {
      width: canvas.width,
      height: canvas.height
    });
    renderer.gpu.device.queue.submit([commandEncoder.finish()]);
    return canvas;
  }
  getPixels(texture) {
    const webGPUCanvas = this.generateCanvas(texture);
    const canvasAndContext = CanvasPool.getOptimalCanvasAndContext(webGPUCanvas.width, webGPUCanvas.height);
    const context = canvasAndContext.context;
    context.drawImage(webGPUCanvas, 0, 0);
    const { width, height } = webGPUCanvas;
    const imageData = context.getImageData(0, 0, width, height);
    const pixels = new Uint8ClampedArray(imageData.data.buffer);
    CanvasPool.returnCanvasAndContext(canvasAndContext);
    return { pixels, width, height };
  }
  destroy() {
    this._managedTextures.destroy();
    for (const k of Object.keys(this._bindGroupHash)) {
      const key = Number(k);
      const bindGroup = this._bindGroupHash[key];
      bindGroup?.destroy();
    }
    this._renderer = null;
    this._gpu = null;
    this._mipmapGenerator = null;
    this._gpuSamplers = null;
    this._bindGroupHash = null;
  }
}
/** @ignore */
GpuTextureSystem.extension = {
  type: [
    ExtensionType.WebGPUSystem
  ],
  name: "texture"
};

export { GPUTextureGpuData, GpuTextureSystem };
//# sourceMappingURL=GpuTextureSystem.mjs.map
