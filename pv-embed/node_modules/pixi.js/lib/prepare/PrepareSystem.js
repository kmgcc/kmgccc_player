'use strict';

var Extensions = require('../extensions/Extensions.js');
var PrepareUpload = require('./PrepareUpload.js');

"use strict";
class PrepareSystem extends PrepareUpload.PrepareUpload {
  /** Destroys the plugin, don't use after this. */
  destroy() {
    super.destroy();
    clearTimeout(this.timeout);
    this.renderer = null;
    this.queue = null;
    this.resolves = null;
  }
}
/** @ignore */
PrepareSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem,
    Extensions.ExtensionType.WebGPUSystem
  ],
  name: "prepare"
};

exports.PrepareSystem = PrepareSystem;
//# sourceMappingURL=PrepareSystem.js.map
