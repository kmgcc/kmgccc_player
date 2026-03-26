'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var GCManagedHash = require('../../../utils/data/GCManagedHash.js');
var updateTextBounds = require('../utils/updateTextBounds.js');
var BatchableText = require('./BatchableText.js');

"use strict";
class CanvasTextPipe {
  constructor(renderer) {
    this._renderer = renderer;
    renderer.runners.resolutionChange.add(this);
    this._managedTexts = new GCManagedHash.GCManagedHash({
      renderer,
      type: "renderable",
      onUnload: this.onTextUnload.bind(this),
      name: "canvasText"
    });
  }
  resolutionChange() {
    for (const key in this._managedTexts.items) {
      const text = this._managedTexts.items[key];
      if (text?._autoResolution) text.onViewUpdate();
    }
  }
  validateRenderable(text) {
    const gpuText = this._getGpuText(text);
    const newKey = text.styleKey;
    if (gpuText.currentKey !== newKey) return true;
    return text._didTextUpdate;
  }
  addRenderable(text, instructionSet) {
    const batchableText = this._getGpuText(text);
    if (text._didTextUpdate) {
      const resolution = text._autoResolution ? this._renderer.resolution : text.resolution;
      if (batchableText.currentKey !== text.styleKey || text._resolution !== resolution) {
        this._updateGpuText(text);
      }
      text._didTextUpdate = false;
      updateTextBounds.updateTextBounds(batchableText, text);
    }
    this._renderer.renderPipes.batch.addToBatch(batchableText, instructionSet);
  }
  updateRenderable(text) {
    const batchableText = this._getGpuText(text);
    batchableText._batcher.updateElement(batchableText);
  }
  _updateGpuText(text) {
    const batchableText = this._getGpuText(text);
    if (batchableText.texture) {
      this._renderer.canvasText.decreaseReferenceCount(batchableText.currentKey);
    }
    text._resolution = text._autoResolution ? this._renderer.resolution : text.resolution;
    batchableText.texture = this._renderer.canvasText.getManagedTexture(text);
    batchableText.currentKey = text.styleKey;
  }
  _getGpuText(text) {
    return text._gpuData[this._renderer.uid] || this.initGpuText(text);
  }
  initGpuText(text) {
    const batchableText = new BatchableText.BatchableText();
    batchableText.currentKey = "--";
    batchableText.renderable = text;
    batchableText.transform = text.groupTransform;
    batchableText.bounds = { minX: 0, maxX: 1, minY: 0, maxY: 0 };
    batchableText.roundPixels = this._renderer._roundPixels | text._roundPixels;
    text._gpuData[this._renderer.uid] = batchableText;
    this._managedTexts.add(text);
    return batchableText;
  }
  onTextUnload(text) {
    const gpuData = text._gpuData[this._renderer.uid];
    if (!gpuData) return;
    const { canvasText } = this._renderer;
    const refCount = canvasText.getReferenceCount(gpuData.currentKey);
    if (refCount > 0) {
      canvasText.decreaseReferenceCount(gpuData.currentKey);
    } else if (gpuData.texture) {
      canvasText.returnTexture(gpuData.texture);
    }
  }
  destroy() {
    this._managedTexts.destroy();
    this._renderer = null;
  }
}
/** @ignore */
CanvasTextPipe.extension = {
  type: [
    Extensions.ExtensionType.WebGLPipes,
    Extensions.ExtensionType.WebGPUPipes,
    Extensions.ExtensionType.CanvasPipes
  ],
  name: "text"
};

exports.CanvasTextPipe = CanvasTextPipe;
//# sourceMappingURL=CanvasTextPipe.js.map
