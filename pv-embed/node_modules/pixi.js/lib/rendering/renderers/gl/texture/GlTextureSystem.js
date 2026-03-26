'use strict';

var adapter = require('../../../../environment/adapter.js');
var Extensions = require('../../../../extensions/Extensions.js');
var GCManagedHash = require('../../../../utils/data/GCManagedHash.js');
var Texture = require('../../shared/texture/Texture.js');
var GlTexture = require('./GlTexture.js');
var glUploadBufferImageResource = require('./uploaders/glUploadBufferImageResource.js');
var glUploadCompressedTextureResource = require('./uploaders/glUploadCompressedTextureResource.js');
var glUploadCubeTextureResource = require('./uploaders/glUploadCubeTextureResource.js');
var glUploadImageResource = require('./uploaders/glUploadImageResource.js');
var glUploadVideoResource = require('./uploaders/glUploadVideoResource.js');
var applyStyleParams = require('./utils/applyStyleParams.js');
var mapFormatToGlFormat = require('./utils/mapFormatToGlFormat.js');
var mapFormatToGlInternalFormat = require('./utils/mapFormatToGlInternalFormat.js');
var mapFormatToGlType = require('./utils/mapFormatToGlType.js');
var mapViewDimensionToGlTarget = require('./utils/mapViewDimensionToGlTarget.js');
require('./utils/unpremultiplyAlpha.js');

"use strict";
const BYTES_PER_PIXEL = 4;
class GlTextureSystem {
  constructor(renderer) {
    this._glSamplers = /* @__PURE__ */ Object.create(null);
    this._boundTextures = [];
    this._activeTextureLocation = -1;
    this._boundSamplers = /* @__PURE__ */ Object.create(null);
    this._premultiplyAlpha = false;
    // TODO - separate samplers will be a cool thing to add, but not right now!
    this._useSeparateSamplers = false;
    this._renderer = renderer;
    this._managedTextures = new GCManagedHash.GCManagedHash({
      renderer,
      type: "resource",
      onUnload: this.onSourceUnload.bind(this),
      name: "glTexture"
    });
    const baseUploaders = {
      image: glUploadImageResource.glUploadImageResource,
      buffer: glUploadBufferImageResource.glUploadBufferImageResource,
      video: glUploadVideoResource.glUploadVideoResource,
      compressed: glUploadCompressedTextureResource.glUploadCompressedTextureResource
    };
    this._uploads = {
      ...baseUploaders,
      cube: glUploadCubeTextureResource.createGlUploadCubeTextureResource(baseUploaders)
    };
  }
  /**
   * @deprecated since 8.15.0
   */
  get managedTextures() {
    return Object.values(this._managedTextures.items);
  }
  contextChange(gl) {
    this._gl = gl;
    if (!this._mapFormatToInternalFormat) {
      this._mapFormatToInternalFormat = mapFormatToGlInternalFormat.mapFormatToGlInternalFormat(gl, this._renderer.context.extensions);
      this._mapFormatToType = mapFormatToGlType.mapFormatToGlType(gl);
      this._mapFormatToFormat = mapFormatToGlFormat.mapFormatToGlFormat(gl);
      this._mapViewDimensionToGlTarget = mapViewDimensionToGlTarget.mapViewDimensionToGlTarget(gl);
    }
    this._managedTextures.removeAll(true);
    this._glSamplers = /* @__PURE__ */ Object.create(null);
    this._boundSamplers = /* @__PURE__ */ Object.create(null);
    this._premultiplyAlpha = false;
    for (let i = 0; i < 16; i++) {
      this.bind(Texture.Texture.EMPTY, i);
    }
  }
  /**
   * Initializes a texture source, if it has already been initialized nothing will happen.
   * @param source - The texture source to initialize.
   * @returns The initialized texture source.
   */
  initSource(source) {
    this.bind(source);
  }
  bind(texture, location = 0) {
    const source = texture.source;
    if (texture) {
      this.bindSource(source, location);
      if (this._useSeparateSamplers) {
        this._bindSampler(source.style, location);
      }
    } else {
      this.bindSource(null, location);
      if (this._useSeparateSamplers) {
        this._bindSampler(null, location);
      }
    }
  }
  bindSource(source, location = 0) {
    const gl = this._gl;
    source._gcLastUsed = this._renderer.gc.now;
    if (this._boundTextures[location] !== source) {
      this._boundTextures[location] = source;
      this._activateLocation(location);
      source || (source = Texture.Texture.EMPTY.source);
      const glTexture = this.getGlSource(source);
      gl.bindTexture(glTexture.target, glTexture.texture);
    }
  }
  _bindSampler(style, location = 0) {
    const gl = this._gl;
    if (!style) {
      this._boundSamplers[location] = null;
      gl.bindSampler(location, null);
      return;
    }
    const sampler = this._getGlSampler(style);
    if (this._boundSamplers[location] !== sampler) {
      this._boundSamplers[location] = sampler;
      gl.bindSampler(location, sampler);
    }
  }
  unbind(texture) {
    const source = texture.source;
    const boundTextures = this._boundTextures;
    const gl = this._gl;
    for (let i = 0; i < boundTextures.length; i++) {
      if (boundTextures[i] === source) {
        this._activateLocation(i);
        const glTexture = this.getGlSource(source);
        gl.bindTexture(glTexture.target, null);
        boundTextures[i] = null;
      }
    }
  }
  _activateLocation(location) {
    if (this._activeTextureLocation !== location) {
      this._activeTextureLocation = location;
      this._gl.activeTexture(this._gl.TEXTURE0 + location);
    }
  }
  _initSource(source) {
    const gl = this._gl;
    const glTexture = new GlTexture.GlTexture(gl.createTexture());
    glTexture.type = this._mapFormatToType[source.format];
    glTexture.internalFormat = this._mapFormatToInternalFormat[source.format];
    glTexture.format = this._mapFormatToFormat[source.format];
    glTexture.target = this._mapViewDimensionToGlTarget[source.viewDimension];
    if (glTexture.target === null) {
      throw new Error(`Unsupported view dimension: ${source.viewDimension} with this webgl version: ${this._renderer.context.webGLVersion}`);
    }
    if (source.uploadMethodId === "cube") {
      glTexture.target = gl.TEXTURE_CUBE_MAP;
    }
    if (source.autoGenerateMipmaps && (this._renderer.context.supports.nonPowOf2mipmaps || source.isPowerOfTwo)) {
      const biggestDimension = Math.max(source.width, source.height);
      source.mipLevelCount = Math.floor(Math.log2(biggestDimension)) + 1;
    }
    source._gpuData[this._renderer.uid] = glTexture;
    const added = this._managedTextures.add(source);
    if (added) {
      source.on("update", this.onSourceUpdate, this);
      source.on("resize", this.onSourceUpdate, this);
      source.on("styleChange", this.onStyleChange, this);
      source.on("updateMipmaps", this.onUpdateMipmaps, this);
    }
    this.onSourceUpdate(source);
    this.updateStyle(source, false);
    return glTexture;
  }
  onStyleChange(source) {
    this.updateStyle(source, false);
  }
  updateStyle(source, firstCreation) {
    const gl = this._gl;
    const glTexture = this.getGlSource(source);
    gl.bindTexture(glTexture.target, glTexture.texture);
    this._boundTextures[this._activeTextureLocation] = source;
    applyStyleParams.applyStyleParams(
      source.style,
      gl,
      source.mipLevelCount > 1,
      this._renderer.context.extensions.anisotropicFiltering,
      "texParameteri",
      glTexture.target,
      // will force a clamp to edge if the texture is not a power of two
      !this._renderer.context.supports.nonPowOf2wrapping && !source.isPowerOfTwo,
      firstCreation
    );
  }
  onSourceUnload(source, contextLost = false) {
    const glTexture = source._gpuData[this._renderer.uid];
    if (!glTexture) return;
    if (!contextLost) {
      this.unbind(source);
      this._gl.deleteTexture(glTexture.texture);
    }
    source.off("update", this.onSourceUpdate, this);
    source.off("resize", this.onSourceUpdate, this);
    source.off("styleChange", this.onStyleChange, this);
    source.off("updateMipmaps", this.onUpdateMipmaps, this);
  }
  onSourceUpdate(source) {
    const gl = this._gl;
    const glTexture = this.getGlSource(source);
    gl.bindTexture(glTexture.target, glTexture.texture);
    this._boundTextures[this._activeTextureLocation] = source;
    const premultipliedAlpha = source.alphaMode === "premultiply-alpha-on-upload";
    if (this._premultiplyAlpha !== premultipliedAlpha) {
      this._premultiplyAlpha = premultipliedAlpha;
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, premultipliedAlpha);
    }
    if (this._uploads[source.uploadMethodId]) {
      this._uploads[source.uploadMethodId].upload(source, glTexture, gl, this._renderer.context.webGLVersion);
    } else if (glTexture.target === gl.TEXTURE_2D) {
      this._initEmptyTexture2D(glTexture, source);
    } else if (glTexture.target === gl.TEXTURE_2D_ARRAY) {
      this._initEmptyTexture2DArray(glTexture, source);
    } else if (glTexture.target === gl.TEXTURE_CUBE_MAP) {
      this._initEmptyTextureCube(glTexture, source);
    } else {
      throw new Error("[GlTextureSystem] Unsupported texture target for empty allocation.");
    }
    this._applyMipRange(glTexture, source);
    if (source.autoGenerateMipmaps && source.mipLevelCount > 1) {
      this.onUpdateMipmaps(source, false);
    }
  }
  onUpdateMipmaps(source, bind = true) {
    if (bind) this.bindSource(source, 0);
    const glTexture = this.getGlSource(source);
    this._gl.generateMipmap(glTexture.target);
  }
  _initEmptyTexture2D(glTexture, source) {
    const gl = this._gl;
    gl.texImage2D(
      gl.TEXTURE_2D,
      0,
      glTexture.internalFormat,
      source.pixelWidth,
      source.pixelHeight,
      0,
      glTexture.format,
      glTexture.type,
      null
    );
    let w = Math.max(source.pixelWidth >> 1, 1);
    let h = Math.max(source.pixelHeight >> 1, 1);
    for (let level = 1; level < source.mipLevelCount; level++) {
      gl.texImage2D(
        gl.TEXTURE_2D,
        level,
        glTexture.internalFormat,
        w,
        h,
        0,
        glTexture.format,
        glTexture.type,
        null
      );
      w = Math.max(w >> 1, 1);
      h = Math.max(h >> 1, 1);
    }
  }
  _initEmptyTexture2DArray(glTexture, source) {
    if (this._renderer.context.webGLVersion !== 2) {
      throw new Error("[GlTextureSystem] TEXTURE_2D_ARRAY requires WebGL2.");
    }
    const gl2 = this._gl;
    const depth = Math.max(source.arrayLayerCount | 0, 1);
    gl2.texImage3D(
      gl2.TEXTURE_2D_ARRAY,
      0,
      glTexture.internalFormat,
      source.pixelWidth,
      source.pixelHeight,
      depth,
      0,
      glTexture.format,
      glTexture.type,
      null
    );
    let w = Math.max(source.pixelWidth >> 1, 1);
    let h = Math.max(source.pixelHeight >> 1, 1);
    for (let level = 1; level < source.mipLevelCount; level++) {
      gl2.texImage3D(
        gl2.TEXTURE_2D_ARRAY,
        level,
        glTexture.internalFormat,
        w,
        h,
        depth,
        0,
        glTexture.format,
        glTexture.type,
        null
      );
      w = Math.max(w >> 1, 1);
      h = Math.max(h >> 1, 1);
    }
  }
  _initEmptyTextureCube(glTexture, source) {
    const gl = this._gl;
    const totalCubeFaces = 6;
    for (let face = 0; face < totalCubeFaces; face++) {
      gl.texImage2D(
        gl.TEXTURE_CUBE_MAP_POSITIVE_X + face,
        0,
        glTexture.internalFormat,
        source.pixelWidth,
        source.pixelHeight,
        0,
        glTexture.format,
        glTexture.type,
        null
      );
    }
    let w = Math.max(source.pixelWidth >> 1, 1);
    let h = Math.max(source.pixelHeight >> 1, 1);
    for (let level = 1; level < source.mipLevelCount; level++) {
      for (let face = 0; face < totalCubeFaces; face++) {
        gl.texImage2D(
          gl.TEXTURE_CUBE_MAP_POSITIVE_X + face,
          level,
          glTexture.internalFormat,
          w,
          h,
          0,
          glTexture.format,
          glTexture.type,
          null
        );
      }
      w = Math.max(w >> 1, 1);
      h = Math.max(h >> 1, 1);
    }
  }
  /**
   * Applies a mip range to the currently-bound texture so WebGL2 considers the texture "mipmap complete"
   * for the declared `mipLevelCount` (especially important for partial mip chains rendered via FBO).
   * @param glTexture - The GL texture wrapper.
   * @param source - The texture source describing mipLevelCount.
   */
  _applyMipRange(glTexture, source) {
    if (this._renderer.context.webGLVersion !== 2) return;
    const gl = this._gl;
    const maxLevel = Math.max((source.mipLevelCount | 0) - 1, 0);
    gl.texParameteri(glTexture.target, gl.TEXTURE_BASE_LEVEL, 0);
    gl.texParameteri(glTexture.target, gl.TEXTURE_MAX_LEVEL, maxLevel);
  }
  _initSampler(style) {
    const gl = this._gl;
    const glSampler = this._gl.createSampler();
    this._glSamplers[style._resourceId] = glSampler;
    applyStyleParams.applyStyleParams(
      style,
      gl,
      this._boundTextures[this._activeTextureLocation].mipLevelCount > 1,
      this._renderer.context.extensions.anisotropicFiltering,
      "samplerParameteri",
      glSampler,
      false,
      true
    );
    return this._glSamplers[style._resourceId];
  }
  _getGlSampler(sampler) {
    return this._glSamplers[sampler._resourceId] || this._initSampler(sampler);
  }
  getGlSource(source) {
    source._gcLastUsed = this._renderer.gc.now;
    return source._gpuData[this._renderer.uid] || this._initSource(source);
  }
  generateCanvas(texture) {
    const { pixels, width, height } = this.getPixels(texture);
    const canvas = adapter.DOMAdapter.get().createCanvas();
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext("2d");
    if (ctx) {
      const imageData = ctx.createImageData(width, height);
      imageData.data.set(pixels);
      ctx.putImageData(imageData, 0, 0);
    }
    return canvas;
  }
  getPixels(texture) {
    const resolution = texture.source.resolution;
    const frame = texture.frame;
    const width = Math.max(Math.round(frame.width * resolution), 1);
    const height = Math.max(Math.round(frame.height * resolution), 1);
    const pixels = new Uint8Array(BYTES_PER_PIXEL * width * height);
    const renderer = this._renderer;
    const renderTarget = renderer.renderTarget.getRenderTarget(texture);
    const glRenterTarget = renderer.renderTarget.getGpuRenderTarget(renderTarget);
    const gl = renderer.gl;
    gl.bindFramebuffer(gl.FRAMEBUFFER, glRenterTarget.resolveTargetFramebuffer);
    gl.readPixels(
      Math.round(frame.x * resolution),
      Math.round(frame.y * resolution),
      width,
      height,
      gl.RGBA,
      gl.UNSIGNED_BYTE,
      pixels
    );
    if (false) {
      unpremultiplyAlpha(pixels);
    }
    return { pixels: new Uint8ClampedArray(pixels.buffer), width, height };
  }
  destroy() {
    this._managedTextures.destroy();
    this._glSamplers = null;
    this._boundTextures = null;
    this._boundSamplers = null;
    this._mapFormatToInternalFormat = null;
    this._mapFormatToType = null;
    this._mapFormatToFormat = null;
    this._uploads = null;
    this._renderer = null;
  }
  resetState() {
    this._activeTextureLocation = -1;
    this._boundTextures.fill(Texture.Texture.EMPTY.source);
    this._boundSamplers = /* @__PURE__ */ Object.create(null);
    const gl = this._gl;
    this._premultiplyAlpha = false;
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, this._premultiplyAlpha);
  }
}
/** @ignore */
GlTextureSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem
  ],
  name: "texture"
};

exports.GlTextureSystem = GlTextureSystem;
//# sourceMappingURL=GlTextureSystem.js.map
