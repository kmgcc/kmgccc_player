'use strict';

var adapter = require('../../../../environment/adapter.js');
var Extensions = require('../../../../extensions/Extensions.js');
var warn = require('../../../../utils/logging/warn.js');

"use strict";
const _GlContextSystem = class _GlContextSystem {
  /** @param renderer - The renderer this System works for. */
  constructor(renderer) {
    /**
     * Features supported by current renderer.
     * @type {object}
     * @readonly
     */
    this.supports = {
      /** Support for 32-bit indices buffer. */
      uint32Indices: true,
      /** Support for UniformBufferObjects */
      uniformBufferObject: true,
      /** Support for VertexArrayObjects */
      vertexArrayObject: true,
      /** Support for SRGB texture format */
      srgbTextures: true,
      /** Support for wrapping modes if a texture is non-power of two */
      nonPowOf2wrapping: true,
      /** Support for MSAA (antialiasing of dynamic textures) */
      msaa: true,
      /** Support for mipmaps if a texture is non-power of two */
      nonPowOf2mipmaps: true
    };
    this._renderer = renderer;
    this.extensions = /* @__PURE__ */ Object.create(null);
    this.handleContextLost = this.handleContextLost.bind(this);
    this.handleContextRestored = this.handleContextRestored.bind(this);
  }
  /**
   * `true` if the context is lost
   * @readonly
   */
  get isLost() {
    return !this.gl || this.gl.isContextLost();
  }
  /**
   * Handles the context change event.
   * @param {WebGLRenderingContext} gl - New WebGL context.
   */
  contextChange(gl) {
    this.gl = gl;
    this._renderer.gl = gl;
  }
  init(options) {
    options = { ..._GlContextSystem.defaultOptions, ...options };
    let multiView = this.multiView = options.multiView;
    if (options.context && multiView) {
      warn.warn("Renderer created with both a context and multiview enabled. Disabling multiView as both cannot work together.");
      multiView = false;
    }
    if (multiView) {
      this.canvas = adapter.DOMAdapter.get().createCanvas(this._renderer.canvas.width, this._renderer.canvas.height);
    } else {
      this.canvas = this._renderer.view.canvas;
    }
    if (options.context) {
      this.initFromContext(options.context);
    } else {
      const alpha = this._renderer.background.alpha < 1;
      const premultipliedAlpha = options.premultipliedAlpha ?? true;
      const antialias = options.antialias && !this._renderer.backBuffer.useBackBuffer;
      this.createContext(options.preferWebGLVersion, {
        alpha,
        premultipliedAlpha,
        antialias,
        stencil: true,
        preserveDrawingBuffer: options.preserveDrawingBuffer,
        powerPreference: options.powerPreference ?? "default"
      });
    }
  }
  ensureCanvasSize(targetCanvas) {
    if (!this.multiView) {
      if (targetCanvas !== this.canvas) {
        warn.warn("multiView is disabled, but targetCanvas is not the main canvas");
      }
      return;
    }
    const { canvas } = this;
    if (canvas.width < targetCanvas.width || canvas.height < targetCanvas.height) {
      canvas.width = Math.max(targetCanvas.width, targetCanvas.width);
      canvas.height = Math.max(targetCanvas.height, targetCanvas.height);
    }
  }
  /**
   * Initializes the context.
   * @protected
   * @param {WebGLRenderingContext} gl - WebGL context
   */
  initFromContext(gl) {
    this.gl = gl;
    this.webGLVersion = gl instanceof adapter.DOMAdapter.get().getWebGLRenderingContext() ? 1 : 2;
    this.getExtensions();
    this.validateContext(gl);
    this._renderer.runners.contextChange.emit(gl);
    const element = this._renderer.view.canvas;
    element.addEventListener("webglcontextlost", this.handleContextLost, false);
    element.addEventListener("webglcontextrestored", this.handleContextRestored, false);
  }
  /**
   * Initialize from context options
   * @protected
   * @see https://developer.mozilla.org/en-US/docs/Web/API/HTMLCanvasElement/getContext
   * @param preferWebGLVersion
   * @param {object} options - context attributes
   */
  createContext(preferWebGLVersion, options) {
    let gl;
    const canvas = this.canvas;
    if (preferWebGLVersion === 2) {
      gl = canvas.getContext("webgl2", options);
    }
    if (!gl) {
      gl = canvas.getContext("webgl", options);
      if (!gl) {
        throw new Error("This browser does not support WebGL. Try using the canvas renderer");
      }
    }
    this.gl = gl;
    this.initFromContext(this.gl);
  }
  /** Auto-populate the {@link GlContextSystem.extensions extensions}. */
  getExtensions() {
    const { gl } = this;
    const common = {
      anisotropicFiltering: gl.getExtension("EXT_texture_filter_anisotropic"),
      floatTextureLinear: gl.getExtension("OES_texture_float_linear"),
      s3tc: gl.getExtension("WEBGL_compressed_texture_s3tc"),
      s3tc_sRGB: gl.getExtension("WEBGL_compressed_texture_s3tc_srgb"),
      // eslint-disable-line camelcase
      etc: gl.getExtension("WEBGL_compressed_texture_etc"),
      etc1: gl.getExtension("WEBGL_compressed_texture_etc1"),
      pvrtc: gl.getExtension("WEBGL_compressed_texture_pvrtc") || gl.getExtension("WEBKIT_WEBGL_compressed_texture_pvrtc"),
      atc: gl.getExtension("WEBGL_compressed_texture_atc"),
      astc: gl.getExtension("WEBGL_compressed_texture_astc"),
      bptc: gl.getExtension("EXT_texture_compression_bptc"),
      rgtc: gl.getExtension("EXT_texture_compression_rgtc"),
      loseContext: gl.getExtension("WEBGL_lose_context")
    };
    if (this.webGLVersion === 1) {
      this.extensions = {
        ...common,
        drawBuffers: gl.getExtension("WEBGL_draw_buffers"),
        depthTexture: gl.getExtension("WEBGL_depth_texture"),
        vertexArrayObject: gl.getExtension("OES_vertex_array_object") || gl.getExtension("MOZ_OES_vertex_array_object") || gl.getExtension("WEBKIT_OES_vertex_array_object"),
        uint32ElementIndex: gl.getExtension("OES_element_index_uint"),
        // Floats and half-floats
        floatTexture: gl.getExtension("OES_texture_float"),
        floatTextureLinear: gl.getExtension("OES_texture_float_linear"),
        textureHalfFloat: gl.getExtension("OES_texture_half_float"),
        textureHalfFloatLinear: gl.getExtension("OES_texture_half_float_linear"),
        vertexAttribDivisorANGLE: gl.getExtension("ANGLE_instanced_arrays"),
        srgb: gl.getExtension("EXT_sRGB")
      };
    } else {
      this.extensions = {
        ...common,
        colorBufferFloat: gl.getExtension("EXT_color_buffer_float")
      };
      const provokeExt = gl.getExtension("WEBGL_provoking_vertex");
      if (provokeExt) {
        provokeExt.provokingVertexWEBGL(provokeExt.FIRST_VERTEX_CONVENTION_WEBGL);
      }
    }
  }
  /**
   * Handles a lost webgl context
   * @param {WebGLContextEvent} event - The context lost event.
   */
  handleContextLost(event) {
    event.preventDefault();
    if (this._contextLossForced) {
      this._contextLossForced = false;
      setTimeout(() => {
        if (this.gl.isContextLost()) {
          this.extensions.loseContext?.restoreContext();
        }
      }, 0);
    }
  }
  /** Handles a restored webgl context. */
  handleContextRestored() {
    this.getExtensions();
    this._renderer.runners.contextChange.emit(this.gl);
  }
  destroy() {
    const element = this._renderer.view.canvas;
    this._renderer = null;
    element.removeEventListener("webglcontextlost", this.handleContextLost);
    element.removeEventListener("webglcontextrestored", this.handleContextRestored);
    this.gl.useProgram(null);
    this.extensions.loseContext?.loseContext();
  }
  /**
   * this function can be called to force a webGL context loss
   * this will release all resources on the GPU.
   * Useful if you need to put Pixi to sleep, and save some GPU memory
   *
   * As soon as render is called - all resources will be created again.
   */
  forceContextLoss() {
    this.extensions.loseContext?.loseContext();
    this._contextLossForced = true;
  }
  /**
   * Validate context.
   * @param {WebGLRenderingContext} gl - Render context.
   */
  validateContext(gl) {
    const attributes = gl.getContextAttributes();
    if (attributes && !attributes.stencil) {
      warn.warn("Provided WebGL context does not have a stencil buffer, masks may not render correctly");
    }
    const supports = this.supports;
    const isWebGl2 = this.webGLVersion === 2;
    const extensions = this.extensions;
    supports.uint32Indices = isWebGl2 || !!extensions.uint32ElementIndex;
    supports.uniformBufferObject = isWebGl2;
    supports.vertexArrayObject = isWebGl2 || !!extensions.vertexArrayObject;
    supports.srgbTextures = isWebGl2 || !!extensions.srgb;
    supports.nonPowOf2wrapping = isWebGl2;
    supports.nonPowOf2mipmaps = isWebGl2;
    supports.msaa = isWebGl2;
    if (!supports.uint32Indices) {
      warn.warn("Provided WebGL context does not support 32 index buffer, large scenes may not render correctly");
    }
  }
};
/** @ignore */
_GlContextSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem
  ],
  name: "context"
};
/** The default options for the system. */
_GlContextSystem.defaultOptions = {
  /**
   * {@link WebGLOptions.context}
   * @default null
   */
  context: null,
  /**
   * {@link WebGLOptions.premultipliedAlpha}
   * @default true
   */
  premultipliedAlpha: true,
  /**
   * {@link WebGLOptions.preserveDrawingBuffer}
   * @default false
   */
  preserveDrawingBuffer: false,
  /**
   * {@link WebGLOptions.powerPreference}
   * @default default
   */
  powerPreference: void 0,
  /**
   * {@link WebGLOptions.webGLVersion}
   * @default 2
   */
  preferWebGLVersion: 2,
  /**
   * {@link WebGLOptions.multiView}
   * @default false
   */
  multiView: false
};
let GlContextSystem = _GlContextSystem;

exports.GlContextSystem = GlContextSystem;
//# sourceMappingURL=GlContextSystem.js.map
