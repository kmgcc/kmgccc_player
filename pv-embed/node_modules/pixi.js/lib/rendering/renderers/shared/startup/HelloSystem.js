'use strict';

var Extensions = require('../../../../extensions/Extensions.js');
var sayHello = require('../../../../utils/sayHello.js');
var types = require('../../types.js');

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
      if (this._renderer.type === types.RendererType.WEBGL) {
        name += ` ${this._renderer.context.webGLVersion}`;
      }
      sayHello.sayHello(name);
    }
  }
}
/** @ignore */
HelloSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem,
    Extensions.ExtensionType.WebGPUSystem,
    Extensions.ExtensionType.CanvasSystem
  ],
  name: "hello",
  priority: -2
};
/** The default options for the system. */
HelloSystem.defaultOptions = {
  /** {@link WebGLOptions.hello} */
  hello: false
};

exports.HelloSystem = HelloSystem;
//# sourceMappingURL=HelloSystem.js.map
