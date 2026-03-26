'use strict';

var EventEmitter = require('eventemitter3');
var pow2 = require('../../../../../maths/misc/pow2.js');
var definedProps = require('../../../../../scene/container/utils/definedProps.js');
var uid = require('../../../../../utils/data/uid.js');
var TextureStyle = require('../TextureStyle.js');

"use strict";
const _TextureSource = class _TextureSource extends EventEmitter {
  /**
   * @param options - options for creating a new TextureSource
   */
  constructor(options = {}) {
    super();
    this.options = options;
    /** @internal */
    this._gpuData = /* @__PURE__ */ Object.create(null);
    /** @internal */
    this._gcLastUsed = -1;
    /** unique id for this Texture source */
    this.uid = uid.uid("textureSource");
    /**
     * The resource type used by this TextureSource. This is used by the bind groups to determine
     * how to handle this resource.
     * @internal
     */
    this._resourceType = "textureSource";
    /**
     * i unique resource id, used by the bind group systems.
     * This can change if the texture is resized or its resource changes
     * @internal
     */
    this._resourceId = uid.uid("resource");
    /**
     * this is how the backends know how to upload this texture to the GPU
     * It changes depending on the resource type. Classes that extend TextureSource
     * should override this property.
     * @internal
     */
    this.uploadMethodId = "unknown";
    /** @internal */
    this._resolution = 1;
    /** the pixel width of this texture source. This is the REAL pure number, not accounting resolution */
    this.pixelWidth = 1;
    /** the pixel height of this texture source. This is the REAL pure number, not accounting resolution */
    this.pixelHeight = 1;
    /**
     * the width of this texture source, accounting for resolution
     * eg pixelWidth 200, resolution 2, then width will be 100
     */
    this.width = 1;
    /**
     * the height of this texture source, accounting for resolution
     * eg pixelHeight 200, resolution 2, then height will be 100
     */
    this.height = 1;
    /**
     * The number of samples of a multisample texture. This is always 1 for non-multisample textures.
     * To enable multisample for a texture, set antialias to true
     * @internal
     */
    this.sampleCount = 1;
    /**
     * The number of mip levels to generate for this texture.
     * this is overridden if autoGenerateMipmaps is true. it is read only!
     */
    this.mipLevelCount = 1;
    /**
     * Should we auto generate mipmaps for this texture? This will automatically generate mipmaps
     * for this texture when uploading to the GPU. Mipmapped textures take up more memory, but
     * can look better when scaled down.
     *
     * For performance reasons, it is recommended to NOT use this with RenderTextures, as they are often updated every frame.
     * If you do, make sure to call `updateMipmaps` after you update the texture.
     */
    this.autoGenerateMipmaps = false;
    /** the format that the texture data has */
    this.format = "rgba8unorm";
    /** how many dimensions does this texture have? currently v8 only supports 2d */
    this.dimension = "2d";
    /** how this texture is viewed/sampled by shaders (WebGPU view dimension) */
    this.viewDimension = "2d";
    /** how many array layers this texture has (WebGPU depthOrArrayLayers) */
    this.arrayLayerCount = 1;
    /**
     * Only really affects RenderTextures.
     * Should we use antialiasing for this texture. It will look better, but may impact performance as a
     * Blit operation will be required to resolve the texture.
     */
    this.antialias = false;
    /**
     * Used by automatic texture Garbage Collection, stores last GC tick when it was bound
     * @protected
     */
    this._touched = 0;
    /**
     * Used by the batcher to build texture batches. faster to have the variable here!
     * @protected
     */
    this._batchTick = -1;
    /**
     * A temporary batch location for the texture batching. Here for performance reasons only!
     * @protected
     */
    this._textureBindLocation = -1;
    options = { ..._TextureSource.defaultOptions, ...options };
    this.label = options.label ?? "";
    this.resource = options.resource;
    this.autoGarbageCollect = options.autoGarbageCollect;
    this._resolution = options.resolution;
    if (options.width) {
      this.pixelWidth = options.width * this._resolution;
    } else {
      this.pixelWidth = this.resource ? this.resourceWidth ?? 1 : 1;
    }
    if (options.height) {
      this.pixelHeight = options.height * this._resolution;
    } else {
      this.pixelHeight = this.resource ? this.resourceHeight ?? 1 : 1;
    }
    this.width = this.pixelWidth / this._resolution;
    this.height = this.pixelHeight / this._resolution;
    this.format = options.format;
    this.dimension = options.dimensions;
    this.viewDimension = options.viewDimension ?? options.dimensions;
    this.arrayLayerCount = options.arrayLayerCount;
    this.mipLevelCount = options.mipLevelCount;
    this.autoGenerateMipmaps = options.autoGenerateMipmaps;
    this.sampleCount = options.sampleCount;
    this.antialias = options.antialias;
    this.alphaMode = options.alphaMode;
    this.style = new TextureStyle.TextureStyle(definedProps.definedProps(options));
    this.destroyed = false;
    this._refreshPOT();
  }
  /** returns itself */
  get source() {
    return this;
  }
  /** the style of the texture */
  get style() {
    return this._style;
  }
  set style(value) {
    if (this.style === value) return;
    this._style?.off("change", this._onStyleChange, this);
    this._style = value;
    this._style?.on("change", this._onStyleChange, this);
    this._onStyleChange();
  }
  /** Specifies the maximum anisotropy value clamp used by the sampler. */
  set maxAnisotropy(value) {
    this._style.maxAnisotropy = value;
  }
  get maxAnisotropy() {
    return this._style.maxAnisotropy;
  }
  /** setting this will set wrapModeU, wrapModeV and wrapModeW all at once! */
  get addressMode() {
    return this._style.addressMode;
  }
  set addressMode(value) {
    this._style.addressMode = value;
  }
  /** setting this will set wrapModeU, wrapModeV and wrapModeW all at once! */
  get repeatMode() {
    return this._style.addressMode;
  }
  set repeatMode(value) {
    this._style.addressMode = value;
  }
  /** Specifies the sampling behavior when the sample footprint is smaller than or equal to one texel. */
  get magFilter() {
    return this._style.magFilter;
  }
  set magFilter(value) {
    this._style.magFilter = value;
  }
  /** Specifies the sampling behavior when the sample footprint is larger than one texel. */
  get minFilter() {
    return this._style.minFilter;
  }
  set minFilter(value) {
    this._style.minFilter = value;
  }
  /** Specifies behavior for sampling between mipmap levels. */
  get mipmapFilter() {
    return this._style.mipmapFilter;
  }
  set mipmapFilter(value) {
    this._style.mipmapFilter = value;
  }
  /** Specifies the minimum and maximum levels of detail, respectively, used internally when sampling a texture. */
  get lodMinClamp() {
    return this._style.lodMinClamp;
  }
  set lodMinClamp(value) {
    this._style.lodMinClamp = value;
  }
  /** Specifies the minimum and maximum levels of detail, respectively, used internally when sampling a texture. */
  get lodMaxClamp() {
    return this._style.lodMaxClamp;
  }
  set lodMaxClamp(value) {
    this._style.lodMaxClamp = value;
  }
  _onStyleChange() {
    this.emit("styleChange", this);
  }
  /** call this if you have modified the texture outside of the constructor */
  update() {
    if (this.resource) {
      const resolution = this._resolution;
      const didResize = this.resize(this.resourceWidth / resolution, this.resourceHeight / resolution);
      if (didResize) return;
    }
    this.emit("update", this);
  }
  /** Destroys this texture source */
  destroy() {
    this.destroyed = true;
    this.unload();
    this.emit("destroy", this);
    if (this._style) {
      this._style.destroy();
      this._style = null;
    }
    this.uploadMethodId = null;
    this.resource = null;
    this.removeAllListeners();
  }
  /**
   * This will unload the Texture source from the GPU. This will free up the GPU memory
   * As soon as it is required fore rendering, it will be re-uploaded.
   */
  unload() {
    this._resourceId = uid.uid("resource");
    this.emit("change", this);
    this.emit("unload", this);
    for (const key in this._gpuData) {
      this._gpuData[key]?.destroy?.();
    }
    this._gpuData = /* @__PURE__ */ Object.create(null);
  }
  /** the width of the resource. This is the REAL pure number, not accounting resolution   */
  get resourceWidth() {
    const { resource } = this;
    return resource.naturalWidth || resource.videoWidth || resource.displayWidth || resource.width;
  }
  /** the height of the resource. This is the REAL pure number, not accounting resolution */
  get resourceHeight() {
    const { resource } = this;
    return resource.naturalHeight || resource.videoHeight || resource.displayHeight || resource.height;
  }
  /**
   * the resolution of the texture. Changing this number, will not change the number of pixels in the actual texture
   * but will the size of the texture when rendered.
   *
   * changing the resolution of this texture to 2 for example will make it appear twice as small when rendered (as pixel
   * density will have increased)
   */
  get resolution() {
    return this._resolution;
  }
  set resolution(resolution) {
    if (this._resolution === resolution) return;
    this._resolution = resolution;
    this.width = this.pixelWidth / resolution;
    this.height = this.pixelHeight / resolution;
  }
  /**
   * Resize the texture, this is handy if you want to use the texture as a render texture
   * @param width - the new width of the texture
   * @param height - the new height of the texture
   * @param resolution - the new resolution of the texture
   * @returns - if the texture was resized
   */
  resize(width, height, resolution) {
    resolution || (resolution = this._resolution);
    width || (width = this.width);
    height || (height = this.height);
    const newPixelWidth = Math.round(width * resolution);
    const newPixelHeight = Math.round(height * resolution);
    this.width = newPixelWidth / resolution;
    this.height = newPixelHeight / resolution;
    this._resolution = resolution;
    if (this.pixelWidth === newPixelWidth && this.pixelHeight === newPixelHeight) {
      return false;
    }
    this._refreshPOT();
    this.pixelWidth = newPixelWidth;
    this.pixelHeight = newPixelHeight;
    this.emit("resize", this);
    this._resourceId = uid.uid("resource");
    this.emit("change", this);
    return true;
  }
  /**
   * Lets the renderer know that this texture has been updated and its mipmaps should be re-generated.
   * This is only important for RenderTexture instances, as standard Texture instances will have their
   * mipmaps generated on upload. You should call this method after you make any change to the texture
   *
   * The reason for this is is can be quite expensive to update mipmaps for a texture. So by default,
   * We want you, the developer to specify when this action should happen.
   *
   * Generally you don't want to have mipmaps generated on Render targets that are changed every frame,
   */
  updateMipmaps() {
    if (this.autoGenerateMipmaps && this.mipLevelCount > 1) {
      this.emit("updateMipmaps", this);
    }
  }
  set wrapMode(value) {
    this._style.wrapMode = value;
  }
  get wrapMode() {
    return this._style.wrapMode;
  }
  set scaleMode(value) {
    this._style.scaleMode = value;
  }
  /** setting this will set magFilter,minFilter and mipmapFilter all at once!  */
  get scaleMode() {
    return this._style.scaleMode;
  }
  /**
   * Refresh check for isPowerOfTwo texture based on size
   * @private
   */
  _refreshPOT() {
    this.isPowerOfTwo = pow2.isPow2(this.pixelWidth) && pow2.isPow2(this.pixelHeight);
  }
  static test(_resource) {
    throw new Error("Unimplemented");
  }
};
/** The default options used when creating a new TextureSource. override these to add your own defaults */
_TextureSource.defaultOptions = {
  resolution: 1,
  format: "bgra8unorm",
  alphaMode: "premultiply-alpha-on-upload",
  dimensions: "2d",
  viewDimension: "2d",
  arrayLayerCount: 1,
  mipLevelCount: 1,
  autoGenerateMipmaps: false,
  sampleCount: 1,
  antialias: false,
  autoGarbageCollect: false
};
let TextureSource = _TextureSource;

exports.TextureSource = TextureSource;
//# sourceMappingURL=TextureSource.js.map
