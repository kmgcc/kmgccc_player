import { ExtensionType } from '../../../extensions/Extensions.mjs';

"use strict";
class ColorMaskPipe {
  constructor(renderer) {
    this._colorStack = [];
    this._colorStackIndex = 0;
    this._currentColor = 0;
    this._renderer = renderer;
  }
  buildStart() {
    this._colorStack[0] = 15;
    this._colorStackIndex = 1;
    this._currentColor = 15;
  }
  push(mask, _container, instructionSet) {
    const renderer = this._renderer;
    renderer.renderPipes.batch.break(instructionSet);
    const colorStack = this._colorStack;
    colorStack[this._colorStackIndex] = colorStack[this._colorStackIndex - 1] & mask.mask;
    const currentColor = this._colorStack[this._colorStackIndex];
    if (currentColor !== this._currentColor) {
      this._currentColor = currentColor;
      instructionSet.add({
        renderPipeId: "colorMask",
        colorMask: currentColor,
        canBundle: false
      });
    }
    this._colorStackIndex++;
  }
  pop(_mask, _container, instructionSet) {
    const renderer = this._renderer;
    renderer.renderPipes.batch.break(instructionSet);
    const colorStack = this._colorStack;
    this._colorStackIndex--;
    const currentColor = colorStack[this._colorStackIndex - 1];
    if (currentColor !== this._currentColor) {
      this._currentColor = currentColor;
      instructionSet.add({
        renderPipeId: "colorMask",
        colorMask: currentColor,
        canBundle: false
      });
    }
  }
  execute(instruction) {
    const renderer = this._renderer;
    renderer.colorMask.setMask(instruction.colorMask);
  }
  destroy() {
    this._renderer = null;
    this._colorStack = null;
  }
}
/** @ignore */
ColorMaskPipe.extension = {
  type: [
    ExtensionType.WebGLPipes,
    ExtensionType.WebGPUPipes
  ],
  name: "colorMask"
};

export { ColorMaskPipe };
//# sourceMappingURL=ColorMaskPipe.mjs.map
