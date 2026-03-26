'use strict';

var Extensions = require('../../../../extensions/Extensions.js');
var FilterEffect = require('../../../../filters/FilterEffect.js');
var RenderGroup = require('../../../../scene/container/RenderGroup.js');
var warn = require('../../../../utils/logging/warn.js');

"use strict";
const BLEND_MODE_FILTERS = {};
Extensions.extensions.handle(Extensions.ExtensionType.BlendMode, (value) => {
  if (!value.name) {
    throw new Error("BlendMode extension must have a name property");
  }
  BLEND_MODE_FILTERS[value.name] = value.ref;
}, (value) => {
  delete BLEND_MODE_FILTERS[value.name];
});
class BlendModePipe {
  constructor(renderer) {
    this._blendModeStack = [];
    this._isAdvanced = false;
    this._filterHash = /* @__PURE__ */ Object.create(null);
    this._renderer = renderer;
    this._renderer.runners.prerender.add(this);
  }
  prerender() {
    this._activeBlendMode = "normal";
    this._isAdvanced = false;
  }
  /**
   * Push a blend mode onto the internal stack and apply it to the instruction set if needed.
   * @param renderable - The renderable or {@link RenderGroup} associated with the change.
   * @param blendMode - The blend mode to activate.
   * @param instructionSet - The instruction set being built.
   */
  pushBlendMode(renderable, blendMode, instructionSet) {
    this._blendModeStack.push(blendMode);
    this.setBlendMode(renderable, blendMode, instructionSet);
  }
  /**
   * Pop the last blend mode from the stack and apply the new top-of-stack mode.
   * @param instructionSet - The instruction set being built.
   */
  popBlendMode(instructionSet) {
    this._blendModeStack.pop();
    const blendMode = this._blendModeStack[this._activeBlendMode.length - 1] ?? "normal";
    this.setBlendMode(null, blendMode, instructionSet);
  }
  /**
   * Ensure a blend mode switch is added to the instruction set when the mode changes.
   * If an advanced blend mode is active, subsequent renderables will be collected so they can be
   * rendered within a single filter pass.
   * @param renderable - The renderable or {@link RenderGroup} to associate with the change, or null when unwinding.
   * @param blendMode - The target blend mode.
   * @param instructionSet - The instruction set being built.
   */
  setBlendMode(renderable, blendMode, instructionSet) {
    const isRenderGroup = renderable instanceof RenderGroup.RenderGroup;
    if (this._activeBlendMode === blendMode) {
      if (this._isAdvanced && renderable && !isRenderGroup) {
        this._renderableList?.push(renderable);
      }
      return;
    }
    if (this._isAdvanced) this._endAdvancedBlendMode(instructionSet);
    this._activeBlendMode = blendMode;
    if (!renderable) return;
    this._isAdvanced = !!BLEND_MODE_FILTERS[blendMode];
    if (this._isAdvanced) this._beginAdvancedBlendMode(renderable, instructionSet);
  }
  _beginAdvancedBlendMode(renderable, instructionSet) {
    this._renderer.renderPipes.batch.break(instructionSet);
    const blendMode = this._activeBlendMode;
    if (!BLEND_MODE_FILTERS[blendMode]) {
      warn.warn(`Unable to assign BlendMode: '${blendMode}'. You may want to include: import 'pixi.js/advanced-blend-modes'`);
      return;
    }
    const filterEffect = this._ensureFilterEffect(blendMode);
    const isRenderGroup = renderable instanceof RenderGroup.RenderGroup;
    const instruction = {
      renderPipeId: "filter",
      action: "pushFilter",
      filterEffect,
      renderables: isRenderGroup ? null : [renderable],
      container: isRenderGroup ? renderable.root : null,
      canBundle: false
    };
    this._renderableList = instruction.renderables;
    instructionSet.add(instruction);
  }
  _ensureFilterEffect(blendMode) {
    let filterEffect = this._filterHash[blendMode];
    if (!filterEffect) {
      filterEffect = this._filterHash[blendMode] = new FilterEffect.FilterEffect();
      filterEffect.filters = [new BLEND_MODE_FILTERS[blendMode]()];
    }
    return filterEffect;
  }
  _endAdvancedBlendMode(instructionSet) {
    this._isAdvanced = false;
    this._renderableList = null;
    this._renderer.renderPipes.batch.break(instructionSet);
    instructionSet.add({
      renderPipeId: "filter",
      action: "popFilter",
      canBundle: false
    });
  }
  /**
   * called when the instruction build process is starting this will reset internally to the default blend mode
   * @internal
   */
  buildStart() {
    this._isAdvanced = false;
  }
  /**
   * called when the instruction build process is finished, ensuring that if there is an advanced blend mode
   * active, we add the final render instructions added to the instruction set
   * @param instructionSet - The instruction set we are adding to
   * @internal
   */
  buildEnd(instructionSet) {
    if (!this._isAdvanced) return;
    this._endAdvancedBlendMode(instructionSet);
  }
  /** @internal */
  destroy() {
    this._renderer = null;
    this._renderableList = null;
    for (const i in this._filterHash) {
      this._filterHash[i].destroy();
    }
    this._filterHash = null;
  }
}
/** @ignore */
BlendModePipe.extension = {
  type: [
    Extensions.ExtensionType.WebGLPipes,
    Extensions.ExtensionType.WebGPUPipes,
    Extensions.ExtensionType.CanvasPipes
  ],
  name: "blendMode"
};

exports.BlendModePipe = BlendModePipe;
//# sourceMappingURL=BlendModePipe.js.map
