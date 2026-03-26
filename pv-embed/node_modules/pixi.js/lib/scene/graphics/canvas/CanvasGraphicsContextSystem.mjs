import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { InstructionSet } from '../../../rendering/renderers/shared/instructions/InstructionSet.mjs';
import { GCManagedHash } from '../../../utils/data/GCManagedHash.mjs';

"use strict";
class CanvasGraphicsContext {
  constructor() {
    /**
     * Whether this context can be batched.
     * @advanced
     */
    this.isBatchable = false;
  }
  /**
   * Reset cached canvas data.
   * @advanced
   */
  reset() {
    this.isBatchable = false;
    this.context = null;
    if (this.graphicsData) {
      this.graphicsData.destroy();
      this.graphicsData = null;
    }
  }
  /**
   * Destroy the cached data.
   * @advanced
   */
  destroy() {
    this.reset();
  }
}
class CanvasGraphicsContextRenderData {
  constructor() {
    /**
     * Instructions for canvas rendering.
     * @advanced
     */
    this.instructions = new InstructionSet();
  }
  /**
   * Initialize render data.
   * @advanced
   */
  init() {
    this.instructions.reset();
  }
  /**
   * Destroy render data.
   * @advanced
   */
  destroy() {
    this.instructions.destroy();
    this.instructions = null;
  }
}
const _CanvasGraphicsContextSystem = class _CanvasGraphicsContextSystem {
  constructor(renderer) {
    this._renderer = renderer;
    this._managedContexts = new GCManagedHash({ renderer, type: "resource", name: "graphicsContext" });
  }
  /**
   * Runner init called, update the default options
   * @ignore
   */
  init(options) {
    _CanvasGraphicsContextSystem.defaultOptions.bezierSmoothness = options?.bezierSmoothness ?? _CanvasGraphicsContextSystem.defaultOptions.bezierSmoothness;
  }
  /**
   * Returns the render data for a given GraphicsContext.
   * @param context - The GraphicsContext to get the render data for.
   * @internal
   */
  getContextRenderData(context) {
    const gpuContext = this.getGpuContext(context);
    return gpuContext.graphicsData || this._initContextRenderData(context);
  }
  /**
   * Updates the GPU context for a given GraphicsContext.
   * @param context - The GraphicsContext to update.
   * @returns The updated CanvasGraphicsContext.
   * @internal
   */
  updateGpuContext(context) {
    const gpuData = context._gpuData;
    const hasContext = !!gpuData[this._renderer.uid];
    const gpuContext = gpuData[this._renderer.uid] || this._initContext(context);
    if (context.dirty || !hasContext) {
      if (hasContext) {
        gpuContext.reset();
      }
      gpuContext.isBatchable = false;
      context.dirty = false;
    }
    return gpuContext;
  }
  /**
   * Returns the CanvasGraphicsContext for a given GraphicsContext.
   * If it does not exist, it will initialize a new one.
   * @param context - The GraphicsContext to get the CanvasGraphicsContext for.
   * @returns The CanvasGraphicsContext for the given GraphicsContext.
   * @internal
   */
  getGpuContext(context) {
    const gpuData = context._gpuData;
    return gpuData[this._renderer.uid] || this._initContext(context);
  }
  _initContextRenderData(context) {
    const renderData = new CanvasGraphicsContextRenderData();
    const gpuContext = this.getGpuContext(context);
    gpuContext.graphicsData = renderData;
    renderData.init();
    return renderData;
  }
  _initContext(context) {
    const gpuContext = new CanvasGraphicsContext();
    gpuContext.context = context;
    context._gpuData[this._renderer.uid] = gpuContext;
    this._managedContexts.add(context);
    return gpuContext;
  }
  destroy() {
    this._managedContexts.destroy();
    this._renderer = null;
  }
};
/** @ignore */
_CanvasGraphicsContextSystem.extension = {
  type: [
    ExtensionType.CanvasSystem
  ],
  name: "graphicsContext"
};
/** The default options for the GraphicsContextSystem. */
_CanvasGraphicsContextSystem.defaultOptions = {
  /**
   * A value from 0 to 1 that controls the smoothness of bezier curves (the higher the smoother)
   * @default 0.5
   */
  bezierSmoothness: 0.5
};
let CanvasGraphicsContextSystem = _CanvasGraphicsContextSystem;

export { CanvasGraphicsContextSystem };
//# sourceMappingURL=CanvasGraphicsContextSystem.mjs.map
