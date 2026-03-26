'use strict';

var Extensions = require('../../extensions/Extensions.js');
var _const = require('../const.js');

"use strict";
class ApplicationInitHook {
  static init() {
    globalThis.__PIXI_APP_INIT__?.(this, _const.VERSION);
  }
  static destroy() {
  }
}
/** @ignore */
ApplicationInitHook.extension = Extensions.ExtensionType.Application;
class RendererInitHook {
  constructor(renderer) {
    this._renderer = renderer;
  }
  init() {
    globalThis.__PIXI_RENDERER_INIT__?.(this._renderer, _const.VERSION);
  }
  destroy() {
    this._renderer = null;
  }
}
/** @ignore */
RendererInitHook.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem,
    Extensions.ExtensionType.WebGPUSystem
  ],
  name: "initHook",
  priority: -10
};

exports.ApplicationInitHook = ApplicationInitHook;
exports.RendererInitHook = RendererInitHook;
//# sourceMappingURL=globalHooks.js.map
