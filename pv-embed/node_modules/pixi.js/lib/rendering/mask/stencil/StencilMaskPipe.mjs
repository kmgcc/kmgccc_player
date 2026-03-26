import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { CLEAR } from '../../renderers/gl/const.mjs';
import { STENCIL_MODES } from '../../renderers/shared/state/const.mjs';

"use strict";
class StencilMaskPipe {
  constructor(renderer) {
    // used when building and also when executing..
    this._maskStackHash = {};
    this._maskHash = /* @__PURE__ */ new WeakMap();
    this._renderer = renderer;
  }
  push(mask, _container, instructionSet) {
    var _a;
    const effect = mask;
    const renderer = this._renderer;
    renderer.renderPipes.batch.break(instructionSet);
    renderer.renderPipes.blendMode.setBlendMode(effect.mask, "none", instructionSet);
    instructionSet.add({
      renderPipeId: "stencilMask",
      action: "pushMaskBegin",
      mask,
      inverse: _container._maskOptions.inverse,
      canBundle: false
    });
    const maskContainer = effect.mask;
    maskContainer.includeInBuild = true;
    if (!this._maskHash.has(effect)) {
      this._maskHash.set(effect, {
        instructionsStart: 0,
        instructionsLength: 0
      });
    }
    const maskData = this._maskHash.get(effect);
    maskData.instructionsStart = instructionSet.instructionSize;
    maskContainer.collectRenderables(
      instructionSet,
      renderer,
      null
    );
    maskContainer.includeInBuild = false;
    renderer.renderPipes.batch.break(instructionSet);
    instructionSet.add({
      renderPipeId: "stencilMask",
      action: "pushMaskEnd",
      mask,
      inverse: _container._maskOptions.inverse,
      canBundle: false
    });
    const instructionsLength = instructionSet.instructionSize - maskData.instructionsStart - 1;
    maskData.instructionsLength = instructionsLength;
    const renderTargetUid = renderer.renderTarget.renderTarget.uid;
    (_a = this._maskStackHash)[renderTargetUid] ?? (_a[renderTargetUid] = 0);
  }
  pop(mask, _container, instructionSet) {
    const effect = mask;
    const renderer = this._renderer;
    renderer.renderPipes.batch.break(instructionSet);
    renderer.renderPipes.blendMode.setBlendMode(effect.mask, "none", instructionSet);
    instructionSet.add({
      renderPipeId: "stencilMask",
      action: "popMaskBegin",
      inverse: _container._maskOptions.inverse,
      canBundle: false
    });
    const maskData = this._maskHash.get(mask);
    for (let i = 0; i < maskData.instructionsLength; i++) {
      instructionSet.instructions[instructionSet.instructionSize++] = instructionSet.instructions[maskData.instructionsStart++];
    }
    instructionSet.add({
      renderPipeId: "stencilMask",
      action: "popMaskEnd",
      canBundle: false
    });
  }
  execute(instruction) {
    var _a;
    const renderer = this._renderer;
    const gpuRenderer = renderer;
    const renderTargetUid = renderer.renderTarget.renderTarget.uid;
    let maskStackIndex = (_a = this._maskStackHash)[renderTargetUid] ?? (_a[renderTargetUid] = 0);
    if (instruction.action === "pushMaskBegin") {
      gpuRenderer.renderTarget.ensureDepthStencil();
      gpuRenderer.stencil.setStencilMode(STENCIL_MODES.RENDERING_MASK_ADD, maskStackIndex);
      maskStackIndex++;
      gpuRenderer.colorMask.setMask(0);
    } else if (instruction.action === "pushMaskEnd") {
      if (instruction.inverse) {
        gpuRenderer.stencil.setStencilMode(STENCIL_MODES.INVERSE_MASK_ACTIVE, maskStackIndex);
      } else {
        gpuRenderer.stencil.setStencilMode(STENCIL_MODES.MASK_ACTIVE, maskStackIndex);
      }
      gpuRenderer.colorMask.setMask(15);
    } else if (instruction.action === "popMaskBegin") {
      gpuRenderer.colorMask.setMask(0);
      if (maskStackIndex !== 0) {
        gpuRenderer.stencil.setStencilMode(STENCIL_MODES.RENDERING_MASK_REMOVE, maskStackIndex);
      } else {
        gpuRenderer.renderTarget.clear(null, CLEAR.STENCIL);
        gpuRenderer.stencil.setStencilMode(STENCIL_MODES.DISABLED, maskStackIndex);
      }
      maskStackIndex--;
    } else if (instruction.action === "popMaskEnd") {
      if (instruction.inverse) {
        gpuRenderer.stencil.setStencilMode(STENCIL_MODES.INVERSE_MASK_ACTIVE, maskStackIndex);
      } else {
        gpuRenderer.stencil.setStencilMode(STENCIL_MODES.MASK_ACTIVE, maskStackIndex);
      }
      gpuRenderer.colorMask.setMask(15);
    }
    this._maskStackHash[renderTargetUid] = maskStackIndex;
  }
  destroy() {
    this._renderer = null;
    this._maskStackHash = null;
    this._maskHash = null;
  }
}
StencilMaskPipe.extension = {
  type: [
    ExtensionType.WebGLPipes,
    ExtensionType.WebGPUPipes
  ],
  name: "stencilMask"
};

export { StencilMaskPipe };
//# sourceMappingURL=StencilMaskPipe.mjs.map
