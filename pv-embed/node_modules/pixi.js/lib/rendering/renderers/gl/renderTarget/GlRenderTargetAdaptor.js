'use strict';

var Rectangle = require('../../../../maths/shapes/Rectangle.js');
var warn = require('../../../../utils/logging/warn.js');
var CanvasSource = require('../../shared/texture/sources/CanvasSource.js');
var _const = require('../const.js');
var GlRenderTarget = require('../GlRenderTarget.js');

"use strict";
class GlRenderTargetAdaptor {
  constructor() {
    this._clearColorCache = [0, 0, 0, 0];
    this._viewPortCache = new Rectangle.Rectangle();
  }
  init(renderer, renderTargetSystem) {
    this._renderer = renderer;
    this._renderTargetSystem = renderTargetSystem;
    renderer.runners.contextChange.add(this);
  }
  contextChange() {
    this._clearColorCache = [0, 0, 0, 0];
    this._viewPortCache = new Rectangle.Rectangle();
    const gl = this._renderer.gl;
    this._drawBuffersCache = [];
    for (let i = 1; i <= 16; i++) {
      this._drawBuffersCache[i] = Array.from({ length: i }, (_, j) => gl.COLOR_ATTACHMENT0 + j);
    }
  }
  copyToTexture(sourceRenderSurfaceTexture, destinationTexture, originSrc, size, originDest) {
    const renderTargetSystem = this._renderTargetSystem;
    const renderer = this._renderer;
    const glRenderTarget = renderTargetSystem.getGpuRenderTarget(sourceRenderSurfaceTexture);
    const gl = renderer.gl;
    this.finishRenderPass(sourceRenderSurfaceTexture);
    gl.bindFramebuffer(gl.FRAMEBUFFER, glRenderTarget.resolveTargetFramebuffer);
    renderer.texture.bind(destinationTexture, 0);
    gl.copyTexSubImage2D(
      gl.TEXTURE_2D,
      0,
      originDest.x,
      originDest.y,
      originSrc.x,
      originSrc.y,
      size.width,
      size.height
    );
    return destinationTexture;
  }
  startRenderPass(renderTarget, clear = true, clearColor, viewport, mipLevel = 0, layer = 0) {
    const renderTargetSystem = this._renderTargetSystem;
    const source = renderTarget.colorTexture;
    const gpuRenderTarget = renderTargetSystem.getGpuRenderTarget(renderTarget);
    if (layer !== 0 && this._renderer.context.webGLVersion < 2) {
      throw new Error("[RenderTargetSystem] Rendering to array layers requires WebGL2.");
    }
    if (mipLevel > 0) {
      if (gpuRenderTarget.msaa) {
        throw new Error("[RenderTargetSystem] Rendering to mip levels is not supported with MSAA render targets.");
      }
      if (this._renderer.context.webGLVersion < 2) {
        throw new Error("[RenderTargetSystem] Rendering to mip levels requires WebGL2.");
      }
    }
    let viewPortY = viewport.y;
    if (renderTarget.isRoot) {
      viewPortY = source.pixelHeight - viewport.height - viewport.y;
    }
    renderTarget.colorTextures.forEach((texture) => {
      this._renderer.texture.unbind(texture);
    });
    const gl = this._renderer.gl;
    gl.bindFramebuffer(gl.FRAMEBUFFER, gpuRenderTarget.framebuffer);
    if (!renderTarget.isRoot && (gpuRenderTarget._attachedMipLevel !== mipLevel || gpuRenderTarget._attachedLayer !== layer)) {
      renderTarget.colorTextures.forEach((colorTexture, i) => {
        const glSource = this._renderer.texture.getGlSource(colorTexture);
        if (glSource.target === gl.TEXTURE_2D) {
          if (layer !== 0) {
            throw new Error("[RenderTargetSystem] layer must be 0 when rendering to 2D textures in WebGL.");
          }
          gl.framebufferTexture2D(
            gl.FRAMEBUFFER,
            gl.COLOR_ATTACHMENT0 + i,
            gl.TEXTURE_2D,
            glSource.texture,
            mipLevel
          );
        } else if (glSource.target === gl.TEXTURE_2D_ARRAY) {
          if (this._renderer.context.webGLVersion < 2) {
            throw new Error("[RenderTargetSystem] Rendering to 2D array textures requires WebGL2.");
          }
          gl.framebufferTextureLayer(
            gl.FRAMEBUFFER,
            gl.COLOR_ATTACHMENT0 + i,
            glSource.texture,
            mipLevel,
            layer
          );
        } else if (glSource.target === gl.TEXTURE_CUBE_MAP) {
          if (layer < 0 || layer > 5) {
            throw new Error("[RenderTargetSystem] Cube map layer must be between 0 and 5.");
          }
          gl.framebufferTexture2D(
            gl.FRAMEBUFFER,
            gl.COLOR_ATTACHMENT0 + i,
            gl.TEXTURE_CUBE_MAP_POSITIVE_X + layer,
            glSource.texture,
            mipLevel
          );
        } else {
          throw new Error("[RenderTargetSystem] Unsupported texture target for render-to-layer in WebGL.");
        }
      });
      gpuRenderTarget._attachedMipLevel = mipLevel;
      gpuRenderTarget._attachedLayer = layer;
    }
    if (renderTarget.colorTextures.length > 1) {
      this._setDrawBuffers(renderTarget, gl);
    }
    const viewPortCache = this._viewPortCache;
    if (viewPortCache.x !== viewport.x || viewPortCache.y !== viewPortY || viewPortCache.width !== viewport.width || viewPortCache.height !== viewport.height) {
      viewPortCache.x = viewport.x;
      viewPortCache.y = viewPortY;
      viewPortCache.width = viewport.width;
      viewPortCache.height = viewport.height;
      gl.viewport(
        viewport.x,
        viewPortY,
        viewport.width,
        viewport.height
      );
    }
    if (!gpuRenderTarget.depthStencilRenderBuffer && (renderTarget.stencil || renderTarget.depth)) {
      this._initStencil(gpuRenderTarget);
    }
    this.clear(renderTarget, clear, clearColor);
  }
  finishRenderPass(renderTarget) {
    const renderTargetSystem = this._renderTargetSystem;
    const glRenderTarget = renderTargetSystem.getGpuRenderTarget(renderTarget);
    if (!glRenderTarget.msaa) return;
    const gl = this._renderer.gl;
    gl.bindFramebuffer(gl.FRAMEBUFFER, glRenderTarget.resolveTargetFramebuffer);
    gl.bindFramebuffer(gl.READ_FRAMEBUFFER, glRenderTarget.framebuffer);
    gl.blitFramebuffer(
      0,
      0,
      glRenderTarget.width,
      glRenderTarget.height,
      0,
      0,
      glRenderTarget.width,
      glRenderTarget.height,
      gl.COLOR_BUFFER_BIT,
      gl.NEAREST
    );
    gl.bindFramebuffer(gl.FRAMEBUFFER, glRenderTarget.framebuffer);
  }
  initGpuRenderTarget(renderTarget) {
    const renderer = this._renderer;
    const gl = renderer.gl;
    const glRenderTarget = new GlRenderTarget.GlRenderTarget();
    glRenderTarget._attachedMipLevel = 0;
    glRenderTarget._attachedLayer = 0;
    const colorTexture = renderTarget.colorTexture;
    if (colorTexture instanceof CanvasSource.CanvasSource) {
      this._renderer.context.ensureCanvasSize(renderTarget.colorTexture.resource);
      glRenderTarget.framebuffer = null;
      return glRenderTarget;
    }
    this._initColor(renderTarget, glRenderTarget);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    return glRenderTarget;
  }
  destroyGpuRenderTarget(gpuRenderTarget) {
    const gl = this._renderer.gl;
    if (gpuRenderTarget.framebuffer) {
      gl.deleteFramebuffer(gpuRenderTarget.framebuffer);
      gpuRenderTarget.framebuffer = null;
    }
    if (gpuRenderTarget.resolveTargetFramebuffer) {
      gl.deleteFramebuffer(gpuRenderTarget.resolveTargetFramebuffer);
      gpuRenderTarget.resolveTargetFramebuffer = null;
    }
    if (gpuRenderTarget.depthStencilRenderBuffer) {
      gl.deleteRenderbuffer(gpuRenderTarget.depthStencilRenderBuffer);
      gpuRenderTarget.depthStencilRenderBuffer = null;
    }
    gpuRenderTarget.msaaRenderBuffer.forEach((renderBuffer) => {
      gl.deleteRenderbuffer(renderBuffer);
    });
    gpuRenderTarget.msaaRenderBuffer = null;
  }
  clear(_renderTarget, clear, clearColor, _viewport, _mipLevel = 0, layer = 0) {
    if (!clear) return;
    if (layer !== 0) {
      throw new Error("[RenderTargetSystem] Clearing array layers is not supported in WebGL renderer.");
    }
    const renderTargetSystem = this._renderTargetSystem;
    if (typeof clear === "boolean") {
      clear = clear ? _const.CLEAR.ALL : _const.CLEAR.NONE;
    }
    const gl = this._renderer.gl;
    if (clear & _const.CLEAR.COLOR) {
      clearColor ?? (clearColor = renderTargetSystem.defaultClearColor);
      const clearColorCache = this._clearColorCache;
      const clearColorArray = clearColor;
      if (clearColorCache[0] !== clearColorArray[0] || clearColorCache[1] !== clearColorArray[1] || clearColorCache[2] !== clearColorArray[2] || clearColorCache[3] !== clearColorArray[3]) {
        clearColorCache[0] = clearColorArray[0];
        clearColorCache[1] = clearColorArray[1];
        clearColorCache[2] = clearColorArray[2];
        clearColorCache[3] = clearColorArray[3];
        gl.clearColor(clearColorArray[0], clearColorArray[1], clearColorArray[2], clearColorArray[3]);
      }
    }
    gl.clear(clear);
  }
  resizeGpuRenderTarget(renderTarget) {
    if (renderTarget.isRoot) return;
    const renderTargetSystem = this._renderTargetSystem;
    const glRenderTarget = renderTargetSystem.getGpuRenderTarget(renderTarget);
    this._resizeColor(renderTarget, glRenderTarget);
    if (renderTarget.stencil || renderTarget.depth) {
      this._resizeStencil(glRenderTarget);
    }
  }
  _initColor(renderTarget, glRenderTarget) {
    const renderer = this._renderer;
    const gl = renderer.gl;
    const resolveTargetFramebuffer = gl.createFramebuffer();
    glRenderTarget.resolveTargetFramebuffer = resolveTargetFramebuffer;
    gl.bindFramebuffer(gl.FRAMEBUFFER, resolveTargetFramebuffer);
    glRenderTarget.width = renderTarget.colorTexture.source.pixelWidth;
    glRenderTarget.height = renderTarget.colorTexture.source.pixelHeight;
    const colorTextures = renderTarget.colorTextures;
    colorTextures.forEach((colorTexture, i) => {
      const source = colorTexture.source;
      if (source.antialias) {
        if (renderer.context.supports.msaa) {
          glRenderTarget.msaa = true;
        } else {
          warn.warn("[RenderTexture] Antialiasing on textures is not supported in WebGL1");
        }
      }
      renderer.texture.bindSource(source, 0);
      const glSource = renderer.texture.getGlSource(source);
      const glTexture = glSource.texture;
      if (glSource.target === gl.TEXTURE_2D) {
        gl.framebufferTexture2D(
          gl.FRAMEBUFFER,
          gl.COLOR_ATTACHMENT0 + i,
          gl.TEXTURE_2D,
          glTexture,
          0
        );
      } else if (glSource.target === gl.TEXTURE_2D_ARRAY) {
        if (renderer.context.webGLVersion < 2) {
          throw new Error("[RenderTargetSystem] TEXTURE_2D_ARRAY requires WebGL2.");
        }
        gl.framebufferTextureLayer(
          gl.FRAMEBUFFER,
          gl.COLOR_ATTACHMENT0 + i,
          glTexture,
          0,
          0
        );
      } else if (glSource.target === gl.TEXTURE_CUBE_MAP) {
        gl.framebufferTexture2D(
          gl.FRAMEBUFFER,
          gl.COLOR_ATTACHMENT0 + i,
          gl.TEXTURE_CUBE_MAP_POSITIVE_X,
          glTexture,
          0
        );
      } else {
        throw new Error("[RenderTargetSystem] Unsupported texture target for framebuffer attachment.");
      }
    });
    if (glRenderTarget.msaa) {
      const viewFramebuffer = gl.createFramebuffer();
      glRenderTarget.framebuffer = viewFramebuffer;
      gl.bindFramebuffer(gl.FRAMEBUFFER, viewFramebuffer);
      renderTarget.colorTextures.forEach((_, i) => {
        const msaaRenderBuffer = gl.createRenderbuffer();
        glRenderTarget.msaaRenderBuffer[i] = msaaRenderBuffer;
      });
    } else {
      glRenderTarget.framebuffer = resolveTargetFramebuffer;
    }
    this._resizeColor(renderTarget, glRenderTarget);
  }
  _resizeColor(renderTarget, glRenderTarget) {
    const source = renderTarget.colorTexture.source;
    glRenderTarget.width = source.pixelWidth;
    glRenderTarget.height = source.pixelHeight;
    glRenderTarget._attachedMipLevel = 0;
    glRenderTarget._attachedLayer = 0;
    renderTarget.colorTextures.forEach((colorTexture, i) => {
      if (i === 0) return;
      colorTexture.source.resize(source.width, source.height, source._resolution);
    });
    if (glRenderTarget.msaa) {
      const renderer = this._renderer;
      const gl = renderer.gl;
      const viewFramebuffer = glRenderTarget.framebuffer;
      gl.bindFramebuffer(gl.FRAMEBUFFER, viewFramebuffer);
      renderTarget.colorTextures.forEach((colorTexture, i) => {
        const source2 = colorTexture.source;
        renderer.texture.bindSource(source2, 0);
        const glSource = renderer.texture.getGlSource(source2);
        const glInternalFormat = glSource.internalFormat;
        const msaaRenderBuffer = glRenderTarget.msaaRenderBuffer[i];
        gl.bindRenderbuffer(
          gl.RENDERBUFFER,
          msaaRenderBuffer
        );
        gl.renderbufferStorageMultisample(
          gl.RENDERBUFFER,
          4,
          glInternalFormat,
          source2.pixelWidth,
          source2.pixelHeight
        );
        gl.framebufferRenderbuffer(
          gl.FRAMEBUFFER,
          gl.COLOR_ATTACHMENT0 + i,
          gl.RENDERBUFFER,
          msaaRenderBuffer
        );
      });
    }
  }
  _initStencil(glRenderTarget) {
    if (glRenderTarget.framebuffer === null) return;
    const gl = this._renderer.gl;
    const depthStencilRenderBuffer = gl.createRenderbuffer();
    glRenderTarget.depthStencilRenderBuffer = depthStencilRenderBuffer;
    gl.bindRenderbuffer(
      gl.RENDERBUFFER,
      depthStencilRenderBuffer
    );
    gl.framebufferRenderbuffer(
      gl.FRAMEBUFFER,
      gl.DEPTH_STENCIL_ATTACHMENT,
      gl.RENDERBUFFER,
      depthStencilRenderBuffer
    );
    this._resizeStencil(glRenderTarget);
  }
  _resizeStencil(glRenderTarget) {
    const gl = this._renderer.gl;
    gl.bindRenderbuffer(
      gl.RENDERBUFFER,
      glRenderTarget.depthStencilRenderBuffer
    );
    if (glRenderTarget.msaa) {
      gl.renderbufferStorageMultisample(
        gl.RENDERBUFFER,
        4,
        gl.DEPTH24_STENCIL8,
        glRenderTarget.width,
        glRenderTarget.height
      );
    } else {
      gl.renderbufferStorage(
        gl.RENDERBUFFER,
        this._renderer.context.webGLVersion === 2 ? gl.DEPTH24_STENCIL8 : gl.DEPTH_STENCIL,
        glRenderTarget.width,
        glRenderTarget.height
      );
    }
  }
  prerender(renderTarget) {
    const resource = renderTarget.colorTexture.resource;
    if (this._renderer.context.multiView && CanvasSource.CanvasSource.test(resource)) {
      this._renderer.context.ensureCanvasSize(resource);
    }
  }
  postrender(renderTarget) {
    if (!this._renderer.context.multiView) return;
    if (CanvasSource.CanvasSource.test(renderTarget.colorTexture.resource)) {
      const contextCanvas = this._renderer.context.canvas;
      const canvasSource = renderTarget.colorTexture;
      canvasSource.context2D.drawImage(
        contextCanvas,
        0,
        canvasSource.pixelHeight - contextCanvas.height
      );
    }
  }
  _setDrawBuffers(renderTarget, gl) {
    const count = renderTarget.colorTextures.length;
    const bufferArray = this._drawBuffersCache[count];
    if (this._renderer.context.webGLVersion === 1) {
      const ext = this._renderer.context.extensions.drawBuffers;
      if (!ext) {
        warn.warn("[RenderTexture] This WebGL1 context does not support rendering to multiple targets");
      } else {
        ext.drawBuffersWEBGL(bufferArray);
      }
    } else {
      gl.drawBuffers(bufferArray);
    }
  }
}

exports.GlRenderTargetAdaptor = GlRenderTargetAdaptor;
//# sourceMappingURL=GlRenderTargetAdaptor.js.map
