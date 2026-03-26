'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var State = require('../../../rendering/renderers/shared/state/State.js');
var GCManagedHash = require('../../../utils/data/GCManagedHash.js');

"use strict";
class CanvasGraphicsPipe {
  constructor(renderer, adaptor) {
    this.state = State.State.for2d();
    this.renderer = renderer;
    this._adaptor = adaptor;
    this.renderer.runners.contextChange.add(this);
    this._managedGraphics = new GCManagedHash.GCManagedHash({ renderer, type: "renderable", priority: -1, name: "graphics" });
  }
  contextChange() {
    this._adaptor.contextChange(this.renderer);
  }
  validateRenderable(_graphics) {
    return false;
  }
  addRenderable(graphics, instructionSet) {
    this._managedGraphics.add(graphics);
    this.renderer.renderPipes.batch.break(instructionSet);
    instructionSet.add(graphics);
  }
  updateRenderable(_graphics) {
  }
  execute(graphics) {
    if (!graphics.isRenderable) return;
    this._adaptor.execute(this, graphics);
  }
  destroy() {
    this._managedGraphics.destroy();
    this.renderer = null;
    this._adaptor.destroy();
    this._adaptor = null;
  }
}
/** @ignore */
CanvasGraphicsPipe.extension = {
  type: [
    Extensions.ExtensionType.CanvasPipes
  ],
  name: "graphics"
};

exports.CanvasGraphicsPipe = CanvasGraphicsPipe;
//# sourceMappingURL=CanvasGraphicsPipe.js.map
