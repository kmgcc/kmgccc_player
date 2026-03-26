import { ViewContainer } from '../view/ViewContainer.mjs';

"use strict";
class RenderContainer extends ViewContainer {
  /**
   * @param options - The options for the container.
   */
  constructor(options) {
    if (typeof options === "function") {
      options = { render: options };
    }
    const { render, ...rest } = options;
    super({
      label: "RenderContainer",
      ...rest
    });
    /** @internal */
    this.renderPipeId = "customRender";
    /** @internal */
    this.batched = false;
    if (render) this.render = render;
    this.containsPoint = options.containsPoint ?? (() => false);
    this.addBounds = options.addBounds ?? (() => false);
  }
  /** @private */
  updateBounds() {
    this._bounds.clear();
    this.addBounds(this._bounds);
  }
  /**
   * An overridable function that can be used to render the object using the current renderer.
   * @param _renderer - The current renderer
   */
  render(_renderer) {
  }
}

export { RenderContainer };
//# sourceMappingURL=RenderContainer.mjs.map
