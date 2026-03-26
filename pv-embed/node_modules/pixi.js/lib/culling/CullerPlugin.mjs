import { ExtensionType } from '../extensions/Extensions.mjs';
import { Culler } from './Culler.mjs';

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
      Culler.shared.cull(this.stage, this.renderer.screen, updateTransform);
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
  type: ExtensionType.Application,
  name: "culler"
};

export { CullerPlugin };
//# sourceMappingURL=CullerPlugin.mjs.map
