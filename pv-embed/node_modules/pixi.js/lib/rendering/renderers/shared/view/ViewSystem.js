'use strict';

var adapter = require('../../../../environment/adapter.js');
var Extensions = require('../../../../extensions/Extensions.js');
var Rectangle = require('../../../../maths/shapes/Rectangle.js');
var deprecation = require('../../../../utils/logging/deprecation.js');
var RenderTarget = require('../renderTarget/RenderTarget.js');
var getCanvasTexture = require('../texture/utils/getCanvasTexture.js');

"use strict";
const _ViewSystem = class _ViewSystem {
  /**
   * Whether CSS dimensions of canvas view should be resized to screen dimensions automatically.
   * This is only supported for HTMLCanvasElement and will be ignored if the canvas is an OffscreenCanvas.
   * @type {boolean}
   */
  get autoDensity() {
    return this.texture.source.autoDensity;
  }
  set autoDensity(value) {
    this.texture.source.autoDensity = value;
  }
  /** The resolution / device pixel ratio of the renderer. */
  get resolution() {
    return this.texture.source._resolution;
  }
  set resolution(value) {
    this.texture.source.resize(
      this.texture.source.width,
      this.texture.source.height,
      value
    );
  }
  /**
   * initiates the view system
   * @param options - the options for the view
   */
  init(options) {
    options = {
      ..._ViewSystem.defaultOptions,
      ...options
    };
    if (options.view) {
      deprecation.deprecation(deprecation.v8_0_0, "ViewSystem.view has been renamed to ViewSystem.canvas");
      options.canvas = options.view;
    }
    this.screen = new Rectangle.Rectangle(0, 0, options.width, options.height);
    this.canvas = options.canvas || adapter.DOMAdapter.get().createCanvas();
    this.antialias = !!options.antialias;
    this.texture = getCanvasTexture.getCanvasTexture(this.canvas, options);
    this.renderTarget = new RenderTarget.RenderTarget({
      colorTextures: [this.texture],
      depth: !!options.depth,
      isRoot: true
    });
    this.texture.source.transparent = options.backgroundAlpha < 1;
    this.resolution = options.resolution;
  }
  /**
   * Resizes the screen and canvas to the specified dimensions.
   * @param desiredScreenWidth - The new width of the screen.
   * @param desiredScreenHeight - The new height of the screen.
   * @param resolution
   */
  resize(desiredScreenWidth, desiredScreenHeight, resolution) {
    this.texture.source.resize(desiredScreenWidth, desiredScreenHeight, resolution);
    this.screen.width = this.texture.frame.width;
    this.screen.height = this.texture.frame.height;
  }
  /**
   * Destroys this System and optionally removes the canvas from the dom.
   * @param {options | false} options - The options for destroying the view, or "false".
   * @example
   * viewSystem.destroy();
   * viewSystem.destroy(true);
   * viewSystem.destroy({ removeView: true });
   */
  destroy(options = false) {
    const removeView = typeof options === "boolean" ? options : !!options?.removeView;
    if (removeView && this.canvas.parentNode) {
      this.canvas.parentNode.removeChild(this.canvas);
    }
    this.texture.destroy();
  }
};
/** @ignore */
_ViewSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem,
    Extensions.ExtensionType.WebGPUSystem,
    Extensions.ExtensionType.CanvasSystem
  ],
  name: "view",
  priority: 0
};
/** The default options for the view system. */
_ViewSystem.defaultOptions = {
  /**
   * {@link WebGLOptions.width}
   * @default 800
   */
  width: 800,
  /**
   * {@link WebGLOptions.height}
   * @default 600
   */
  height: 600,
  /**
   * {@link WebGLOptions.autoDensity}
   * @default false
   */
  autoDensity: false,
  /**
   * {@link WebGLOptions.antialias}
   * @default false
   */
  antialias: false
};
let ViewSystem = _ViewSystem;

exports.ViewSystem = ViewSystem;
//# sourceMappingURL=ViewSystem.js.map
