'use strict';

var Extensions = require('../extensions/Extensions.js');
var Culler = require('./Culler.js');

"use strict";
class CullerPlugin {
  /**
   * Initialize the plugin with scope of application instance
   * @private
   * @param {object} [options] - See application options
   */
  static init(options) {
    this._renderRef = this.render.bind(this);
    this.render = () => {
      const updateTransform = options?.culler?.updateTransform !== true;
      Culler.Culler.shared.cull(this.stage, this.renderer.screen, updateTransform);
      this.renderer.render({ container: this.stage });
    };
  }
  /** @internal */
  static destroy() {
    this.render = this._renderRef;
  }
}
/** @ignore */
CullerPlugin.extension = {
  priority: 10,
  type: Extensions.ExtensionType.Application,
  name: "culler"
};

exports.CullerPlugin = CullerPlugin;
//# sourceMappingURL=CullerPlugin.js.map
