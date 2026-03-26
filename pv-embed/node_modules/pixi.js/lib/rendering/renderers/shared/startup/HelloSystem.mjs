import { ExtensionType } from '../../../../extensions/Extensions.mjs';
import { sayHello } from '../../../../utils/sayHello.mjs';
import { RendererType } from '../../types.mjs';

"use strict";
class HelloSystem {
  constructor(renderer) {
    this._renderer = renderer;
  }
  /**
   * It all starts here! This initiates every system, passing in the options for any system by name.
   * @param options - the config for the renderer and all its systems
   */
  init(options) {
    if (options.hello) {
      let name = this._renderer.name;
      if (this._renderer.type === RendererType.WEBGL) {
        name += ` ${this._renderer.context.webGLVersion}`;
      }
      sayHello(name);
    }
  }
}
/** @ignore */
HelloSystem.extension = {
  type: [
    ExtensionType.WebGLSystem,
    ExtensionType.WebGPUSystem,
    ExtensionType.CanvasSystem
  ],
  name: "hello",
  priority: -2
};
/** The default options for the system. */
HelloSystem.defaultOptions = {
  /** {@link WebGLOptions.hello} */
  hello: false
};

export { HelloSystem };
//# sourceMappingURL=HelloSystem.mjs.map
