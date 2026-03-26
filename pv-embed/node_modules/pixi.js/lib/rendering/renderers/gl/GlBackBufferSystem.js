'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var warn = require('../../../utils/logging/warn.js');
var Geometry = require('../shared/geometry/Geometry.js');
var Shader = require('../shared/shader/Shader.js');
var State = require('../shared/state/State.js');
var TextureSource = require('../shared/texture/sources/TextureSource.js');
var Texture = require('../shared/texture/Texture.js');
var GlProgram = require('./shader/GlProgram.js');

"use strict";
const bigTriangleGeometry = new Geometry.Geometry({
  attributes: {
    aPosition: [
      -1,
      -1,
      // Bottom left corner
      3,
      -1,
      // Bottom right corner, extending beyond right edge
      -1,
      3
      // Top left corner, extending beyond top edge
    ]
  }
});
const _GlBackBufferSystem = class _GlBackBufferSystem {
  constructor(renderer) {
    /** if true, the back buffer is used */
    this.useBackBuffer = false;
    this._useBackBufferThisRender = false;
    this._renderer = renderer;
  }
  init(options = {}) {
    const { useBackBuffer, antialias } = { ..._GlBackBufferSystem.defaultOptions, ...options };
    this.useBackBuffer = useBackBuffer;
    this._antialias = antialias;
    if (!this._renderer.context.supports.msaa) {
      warn.warn("antialiasing, is not supported on when using the back buffer");
      this._antialias = false;
    }
    this._state = State.State.for2d();
    const bigTriangleProgram = new GlProgram.GlProgram({
      vertex: `
                attribute vec2 aPosition;
                out vec2 vUv;

                void main() {
                    gl_Position = vec4(aPosition, 0.0, 1.0);

                    vUv = (aPosition + 1.0) / 2.0;

                    // flip dem UVs
                    vUv.y = 1.0 - vUv.y;
                }`,
      fragment: `
                in vec2 vUv;
                out vec4 finalColor;

                uniform sampler2D uTexture;

                void main() {
                    finalColor = texture(uTexture, vUv);
                }`,
      name: "big-triangle"
    });
    this._bigTriangleShader = new Shader.Shader({
      glProgram: bigTriangleProgram,
      resources: {
        uTexture: Texture.Texture.WHITE.source
      }
    });
  }
  /**
   * This is called before the RenderTargetSystem is started. This is where
   * we replace the target with the back buffer if required.
   * @param options - The options for this render.
   */
  renderStart(options) {
    const renderTarget = this._renderer.renderTarget.getRenderTarget(options.target);
    this._useBackBufferThisRender = this.useBackBuffer && !!renderTarget.isRoot;
    if (this._useBackBufferThisRender) {
      const renderTarget2 = this._renderer.renderTarget.getRenderTarget(options.target);
      this._targetTexture = renderTarget2.colorTexture;
      options.target = this._getBackBufferTexture(renderTarget2.colorTexture);
    }
  }
  renderEnd() {
    this._presentBackBuffer();
  }
  _presentBackBuffer() {
    const renderer = this._renderer;
    renderer.renderTarget.finishRenderPass();
    if (!this._useBackBufferThisRender) return;
    renderer.renderTarget.bind(this._targetTexture, false);
    this._bigTriangleShader.resources.uTexture = this._backBufferTexture.source;
    renderer.encoder.draw({
      geometry: bigTriangleGeometry,
      shader: this._bigTriangleShader,
      state: this._state
    });
  }
  _getBackBufferTexture(targetSourceTexture) {
    this._backBufferTexture = this._backBufferTexture || new Texture.Texture({
      source: new TextureSource.TextureSource({
        width: targetSourceTexture.width,
        height: targetSourceTexture.height,
        resolution: targetSourceTexture._resolution,
        antialias: this._antialias
      })
    });
    this._backBufferTexture.source.resize(
      targetSourceTexture.width,
      targetSourceTexture.height,
      targetSourceTexture._resolution
    );
    return this._backBufferTexture;
  }
  /** destroys the back buffer */
  destroy() {
    if (this._backBufferTexture) {
      this._backBufferTexture.destroy();
      this._backBufferTexture = null;
    }
  }
};
/** @ignore */
_GlBackBufferSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem
  ],
  name: "backBuffer",
  priority: 1
};
/** default options for the back buffer system */
_GlBackBufferSystem.defaultOptions = {
  /** if true will use the back buffer where required */
  useBackBuffer: false
};
let GlBackBufferSystem = _GlBackBufferSystem;

exports.GlBackBufferSystem = GlBackBufferSystem;
//# sourceMappingURL=GlBackBufferSystem.js.map
