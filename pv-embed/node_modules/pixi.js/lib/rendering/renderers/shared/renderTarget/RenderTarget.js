'use strict';

var uid = require('../../../../utils/data/uid.js');
var TextureSource = require('../texture/sources/TextureSource.js');
var Texture = require('../texture/Texture.js');

"use strict";
const _RenderTarget = class _RenderTarget {
  /**
   * @param [descriptor] - Options for creating a render target.
   */
  constructor(descriptor = {}) {
    /** unique id for this render target */
    this.uid = uid.uid("renderTarget");
    /**
     * An array of textures that can be written to by the GPU - mostly this has one texture in Pixi, but you could
     * write to multiple if required! (eg deferred lighting)
     */
    this.colorTextures = [];
    this.dirtyId = 0;
    this.isRoot = false;
    this._size = new Float32Array(2);
    /** if true, then when the render target is destroyed, it will destroy all the textures that were created for it. */
    this._managedColorTextures = false;
    descriptor = { ..._RenderTarget.defaultOptions, ...descriptor };
    this.stencil = descriptor.stencil;
    this.depth = descriptor.depth;
    this.isRoot = descriptor.isRoot;
    if (typeof descriptor.colorTextures === "number") {
      this._managedColorTextures = true;
      for (let i = 0; i < descriptor.colorTextures; i++) {
        this.colorTextures.push(
          new TextureSource.TextureSource({
            width: descriptor.width,
            height: descriptor.height,
            resolution: descriptor.resolution,
            antialias: descriptor.antialias
          })
        );
      }
    } else {
      this.colorTextures = [...descriptor.colorTextures.map((texture) => texture.source)];
      const colorSource = this.colorTexture.source;
      this.resize(colorSource.width, colorSource.height, colorSource._resolution);
    }
    this.colorTexture.source.on("resize", this.onSourceResize, this);
    if (descriptor.depthStencilTexture || this.stencil) {
      if (descriptor.depthStencilTexture instanceof Texture.Texture || descriptor.depthStencilTexture instanceof TextureSource.TextureSource) {
        this.depthStencilTexture = descriptor.depthStencilTexture.source;
      } else {
        this.ensureDepthStencilTexture();
      }
    }
  }
  get size() {
    const _size = this._size;
    _size[0] = this.pixelWidth;
    _size[1] = this.pixelHeight;
    return _size;
  }
  get width() {
    return this.colorTexture.source.width;
  }
  get height() {
    return this.colorTexture.source.height;
  }
  get pixelWidth() {
    return this.colorTexture.source.pixelWidth;
  }
  get pixelHeight() {
    return this.colorTexture.source.pixelHeight;
  }
  get resolution() {
    return this.colorTexture.source._resolution;
  }
  get colorTexture() {
    return this.colorTextures[0];
  }
  onSourceResize(source) {
    this.resize(source.width, source.height, source._resolution, true);
  }
  /**
   * This will ensure a depthStencil texture is created for this render target.
   * Most likely called by the mask system to make sure we have stencil buffer added.
   * @internal
   */
  ensureDepthStencilTexture() {
    if (!this.depthStencilTexture) {
      this.depthStencilTexture = new TextureSource.TextureSource({
        width: this.width,
        height: this.height,
        resolution: this.resolution,
        format: "depth24plus-stencil8",
        autoGenerateMipmaps: false,
        antialias: false,
        mipLevelCount: 1
        // sampleCount: handled by the render target system..
      });
    }
  }
  resize(width, height, resolution = this.resolution, skipColorTexture = false) {
    this.dirtyId++;
    this.colorTextures.forEach((colorTexture, i) => {
      if (skipColorTexture && i === 0) return;
      colorTexture.source.resize(width, height, resolution);
    });
    if (this.depthStencilTexture) {
      this.depthStencilTexture.source.resize(width, height, resolution);
    }
  }
  destroy() {
    this.colorTexture.source.off("resize", this.onSourceResize, this);
    if (this._managedColorTextures) {
      this.colorTextures.forEach((texture) => {
        texture.destroy();
      });
    }
    if (this.depthStencilTexture) {
      this.depthStencilTexture.destroy();
      delete this.depthStencilTexture;
    }
  }
};
/** The default options for a render target */
_RenderTarget.defaultOptions = {
  /** the width of the RenderTarget */
  width: 0,
  /** the height of the RenderTarget */
  height: 0,
  /** the resolution of the RenderTarget */
  resolution: 1,
  /** an array of textures, or a number indicating how many color textures there should be */
  colorTextures: 1,
  /** should this render target have a stencil buffer? */
  stencil: false,
  /** should this render target have a depth buffer? */
  depth: false,
  /** should this render target be antialiased? */
  antialias: false,
  // save on perf by default!
  /** is this a root element, true if this is gl context owners render target */
  isRoot: false
};
let RenderTarget = _RenderTarget;

exports.RenderTarget = RenderTarget;
//# sourceMappingURL=RenderTarget.js.map
