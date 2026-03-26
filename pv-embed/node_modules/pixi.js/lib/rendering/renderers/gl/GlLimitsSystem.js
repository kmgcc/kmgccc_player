'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var checkMaxIfStatementsInShader = require('../../batcher/gl/utils/checkMaxIfStatementsInShader.js');

"use strict";
class GlLimitsSystem {
  constructor(renderer) {
    this._renderer = renderer;
  }
  contextChange() {
    const gl = this._renderer.gl;
    this.maxTextures = gl.getParameter(gl.MAX_TEXTURE_IMAGE_UNITS);
    this.maxBatchableTextures = checkMaxIfStatementsInShader.checkMaxIfStatementsInShader(this.maxTextures, gl);
    const isWebGl2 = this._renderer.context.webGLVersion === 2;
    this.maxUniformBindings = isWebGl2 ? gl.getParameter(gl.MAX_UNIFORM_BUFFER_BINDINGS) : 0;
  }
  destroy() {
  }
}
/** @ignore */
GlLimitsSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem
  ],
  name: "limits"
};

exports.GlLimitsSystem = GlLimitsSystem;
//# sourceMappingURL=GlLimitsSystem.js.map
