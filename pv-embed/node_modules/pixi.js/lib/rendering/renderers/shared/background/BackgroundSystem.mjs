import { Color } from '../../../../color/Color.mjs';
import { ExtensionType } from '../../../../extensions/Extensions.mjs';
import { warn } from '../../../../utils/logging/warn.mjs';

"use strict";
const _BackgroundSystem = class _BackgroundSystem {
  constructor() {
    this.clearBeforeRender = true;
    this._backgroundColor = new Color(0);
    this.color = this._backgroundColor;
    this.alpha = 1;
  }
  /**
   * initiates the background system
   * @param options - the options for the background colors
   */
  init(options) {
    options = { ..._BackgroundSystem.defaultOptions, ...options };
    this.clearBeforeRender = options.clearBeforeRender;
    this.color = options.background || options.backgroundColor || this._backgroundColor;
    this.alpha = options.backgroundAlpha;
    this._backgroundColor.setAlpha(options.backgroundAlpha);
  }
  /** The background color to fill if not transparent */
  get color() {
    return this._backgroundColor;
  }
  set color(value) {
    const incoming = Color.shared.setValue(value);
    if (incoming.alpha < 1 && this._backgroundColor.alpha === 1) {
      warn(
        "Cannot set a transparent background on an opaque canvas. To enable transparency, set backgroundAlpha < 1 when initializing your Application."
      );
    }
    this._backgroundColor.setValue(value);
  }
  /** The background color alpha. Setting this to 0 will make the canvas transparent. */
  get alpha() {
    return this._backgroundColor.alpha;
  }
  set alpha(value) {
    this._backgroundColor.setAlpha(value);
  }
  /** The background color as an [R, G, B, A] array. */
  get colorRgba() {
    return this._backgroundColor.toArray();
  }
  /**
   * destroys the background system
   * @internal
   */
  destroy() {
  }
};
/** @ignore */
_BackgroundSystem.extension = {
  type: [
    ExtensionType.WebGLSystem,
    ExtensionType.WebGPUSystem,
    ExtensionType.CanvasSystem
  ],
  name: "background",
  priority: 0
};
/** default options used by the system */
_BackgroundSystem.defaultOptions = {
  /**
   * {@link WebGLOptions.backgroundAlpha}
   * @default 1
   */
  backgroundAlpha: 1,
  /**
   * {@link WebGLOptions.backgroundColor}
   * @default 0x000000
   */
  backgroundColor: 0,
  /**
   * {@link WebGLOptions.clearBeforeRender}
   * @default true
   */
  clearBeforeRender: true
};
let BackgroundSystem = _BackgroundSystem;

export { BackgroundSystem };
//# sourceMappingURL=BackgroundSystem.mjs.map
