'use strict';

var Extensions = require('../../../../extensions/Extensions.js');
var deprecation = require('../../../../utils/logging/deprecation.js');

"use strict";
const _TextureGCSystem = class _TextureGCSystem {
  /**
   * Frame count since started.
   * @readonly
   * @deprecated since 8.15.0
   */
  get count() {
    return this._renderer.tick;
  }
  /**
   * Frame count since last garbage collection.
   * @readonly
   * @deprecated since 8.15.0
   */
  get checkCount() {
    return this._checkCount;
  }
  set checkCount(value) {
    deprecation.deprecation("8.15.0", "TextureGCSystem.run is deprecated, please use the GCSystem instead.");
    this._checkCount = value;
  }
  /**
   * Maximum idle frames before a texture is destroyed by garbage collection.
   * @see TextureGCSystem.defaultMaxIdle
   * @deprecated since 8.15.0
   */
  get maxIdle() {
    return this._renderer.gc.maxUnusedTime / 1e3 * 60;
  }
  set maxIdle(value) {
    deprecation.deprecation("8.15.0", "TextureGCSystem.run is deprecated, please use the GCSystem instead.");
    this._renderer.gc.maxUnusedTime = value / 60 * 1e3;
  }
  /**
   * Frames between two garbage collections.
   * @see TextureGCSystem.defaultCheckCountMax
   * @deprecated since 8.15.0
   */
  // eslint-disable-next-line dot-notation
  get checkCountMax() {
    return Math.floor(this._renderer.gc["_frequency"] / 1e3);
  }
  set checkCountMax(_value) {
    deprecation.deprecation("8.15.0", "TextureGCSystem.run is deprecated, please use the GCSystem instead.");
  }
  /**
   * Current garbage collection mode.
   * @see TextureGCSystem.defaultMode
   * @deprecated since 8.15.0
   */
  get active() {
    return this._renderer.gc.enabled;
  }
  set active(value) {
    deprecation.deprecation("8.15.0", "TextureGCSystem.run is deprecated, please use the GCSystem instead.");
    this._renderer.gc.enabled = value;
  }
  /** @param renderer - The renderer this System works for. */
  constructor(renderer) {
    this._renderer = renderer;
    this._checkCount = 0;
  }
  init(options) {
    if (options.textureGCActive !== _TextureGCSystem.defaultOptions.textureGCActive) {
      this.active = options.textureGCActive;
    }
    if (options.textureGCMaxIdle !== _TextureGCSystem.defaultOptions.textureGCMaxIdle) {
      this.maxIdle = options.textureGCMaxIdle;
    }
    if (options.textureGCCheckCountMax !== _TextureGCSystem.defaultOptions.textureGCCheckCountMax) {
      this.checkCountMax = options.textureGCCheckCountMax;
    }
  }
  /**
   * Checks to see when the last time a texture was used.
   * If the texture has not been used for a specified amount of time, it will be removed from the GPU.
   * @deprecated since 8.15.0
   */
  run() {
    deprecation.deprecation("8.15.0", "TextureGCSystem.run is deprecated, please use the GCSystem instead.");
    this._renderer.gc.run();
  }
  destroy() {
    this._renderer = null;
  }
};
/** @ignore */
_TextureGCSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem,
    Extensions.ExtensionType.WebGPUSystem
  ],
  name: "textureGC"
};
/**
 * Default options for the TextureGCSystem
 * @deprecated since 8.15.0
 */
_TextureGCSystem.defaultOptions = {
  /**
   * If set to true, this will enable the garbage collector on the GPU.
   * @default true
   */
  textureGCActive: true,
  /**
   * @deprecated since 8.3.0
   * @see {@link TextureGCSystemOptions.textureGCMaxIdle}
   */
  textureGCAMaxIdle: null,
  /**
   * The maximum idle frames before a texture is destroyed by garbage collection.
   * @default 60 * 60
   */
  textureGCMaxIdle: 60 * 60,
  /**
   * Frames between two garbage collections.
   * @default 600
   */
  textureGCCheckCountMax: 600
};
let TextureGCSystem = _TextureGCSystem;

exports.TextureGCSystem = TextureGCSystem;
//# sourceMappingURL=TextureGCSystem.js.map
