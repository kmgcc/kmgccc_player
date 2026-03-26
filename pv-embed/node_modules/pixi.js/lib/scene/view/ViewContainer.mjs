import { Bounds } from '../container/bounds/Bounds.mjs';
import { Container } from '../container/Container.mjs';

"use strict";
class ViewContainer extends Container {
  constructor(options) {
    super(options);
    /** @internal */
    this.canBundle = true;
    /** @internal */
    this.allowChildren = false;
    /** @internal */
    this._roundPixels = 0;
    /** @internal */
    this._lastUsed = -1;
    /** @internal */
    this._gpuData = /* @__PURE__ */ Object.create(null);
    /** If set to true, the resource will be garbage collected automatically when it is not used. */
    this.autoGarbageCollect = true;
    /** @internal */
    this._gcLastUsed = -1;
    this._bounds = new Bounds(0, 1, 0, 0);
    this._boundsDirty = true;
    this.autoGarbageCollect = options.autoGarbageCollect ?? true;
  }
  /**
   * The local bounds of the view in its own coordinate space.
   * Bounds are automatically updated when the view's content changes.
   * @example
   * ```ts
   * // Get bounds dimensions
   * const bounds = view.bounds;
   * console.log(`Width: ${bounds.maxX - bounds.minX}`);
   * console.log(`Height: ${bounds.maxY - bounds.minY}`);
   * ```
   * @returns The rectangular bounds of the view
   * @see {@link Bounds} For bounds operations
   */
  get bounds() {
    if (!this._boundsDirty) return this._bounds;
    this.updateBounds();
    this._boundsDirty = false;
    return this._bounds;
  }
  /**
   * Whether or not to round the x/y position of the sprite.
   * @example
   * ```ts
   * // Enable pixel rounding for crisp rendering
   * view.roundPixels = true;
   * ```
   * @default false
   */
  get roundPixels() {
    return !!this._roundPixels;
  }
  set roundPixels(value) {
    this._roundPixels = value ? 1 : 0;
  }
  /**
   * Checks if the object contains the given point in local coordinates.
   * Uses the view's bounds for hit testing.
   * @example
   * ```ts
   * // Basic point check
   * const localPoint = { x: 50, y: 25 };
   * const contains = view.containsPoint(localPoint);
   * console.log('Point is inside:', contains);
   * ```
   * @param point - The point to check in local coordinates
   * @returns True if the point is within the view's bounds
   * @see {@link ViewContainer#bounds} For the bounds used in hit testing
   * @see {@link Container#toLocal} For converting global coordinates to local
   */
  containsPoint(point) {
    const bounds = this.bounds;
    const { x, y } = point;
    return x >= bounds.minX && x <= bounds.maxX && y >= bounds.minY && y <= bounds.maxY;
  }
  /** @private */
  onViewUpdate() {
    this._didViewChangeTick++;
    this._boundsDirty = true;
    if (this.didViewUpdate) return;
    this.didViewUpdate = true;
    const renderGroup = this.renderGroup || this.parentRenderGroup;
    if (renderGroup) {
      renderGroup.onChildViewUpdate(this);
    }
  }
  /** Unloads the GPU data from the view. */
  unload() {
    this.emit("unload", this);
    for (const key in this._gpuData) {
      this._gpuData[key]?.destroy();
    }
    this._gpuData = /* @__PURE__ */ Object.create(null);
    this.onViewUpdate();
  }
  destroy(options) {
    this.unload();
    super.destroy(options);
    this._bounds = null;
  }
  /**
   * Collects renderables for the view container.
   * @param instructionSet - The instruction set to collect renderables for.
   * @param renderer - The renderer to collect renderables for.
   * @param currentLayer - The current render layer.
   * @internal
   */
  collectRenderablesSimple(instructionSet, renderer, currentLayer) {
    const { renderPipes } = renderer;
    renderPipes.blendMode.pushBlendMode(this, this.groupBlendMode, instructionSet);
    const rp = renderPipes;
    const pipe = rp[this.renderPipeId];
    if (pipe?.addRenderable) {
      pipe.addRenderable(this, instructionSet);
    }
    this.didViewUpdate = false;
    const children = this.children;
    const length = children.length;
    for (let i = 0; i < length; i++) {
      children[i].collectRenderables(instructionSet, renderer, currentLayer);
    }
    renderPipes.blendMode.popBlendMode(instructionSet);
  }
}

export { ViewContainer };
//# sourceMappingURL=ViewContainer.mjs.map
