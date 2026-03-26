import { ExtensionType } from '../../extensions/Extensions.mjs';
import { Texture } from '../../rendering/renderers/shared/texture/Texture.mjs';
import { GCManagedHash } from '../../utils/data/GCManagedHash.mjs';
import { updateTextBounds } from '../text/utils/updateTextBounds.mjs';
import { BatchableHTMLText } from './BatchableHTMLText.mjs';

"use strict";
class HTMLTextPipe {
  constructor(renderer) {
    this._renderer = renderer;
    renderer.runners.resolutionChange.add(this);
    this._managedTexts = new GCManagedHash({
      renderer,
      type: "renderable",
      onUnload: this.onTextUnload.bind(this),
      name: "htmlText"
    });
  }
  resolutionChange() {
    for (const key in this._managedTexts.items) {
      const text = this._managedTexts.items[key];
      if (text?._autoResolution) {
        text.onViewUpdate();
      }
    }
  }
  validateRenderable(htmlText) {
    const gpuText = this._getGpuText(htmlText);
    const newKey = htmlText.styleKey;
    if (gpuText.currentKey !== newKey) {
      return true;
    }
    return false;
  }
  addRenderable(htmlText, instructionSet) {
    const batchableHTMLText = this._getGpuText(htmlText);
    if (htmlText._didTextUpdate) {
      const resolution = htmlText._autoResolution ? this._renderer.resolution : htmlText.resolution;
      if (batchableHTMLText.currentKey !== htmlText.styleKey || htmlText.resolution !== resolution) {
        this._updateGpuText(htmlText).catch((e) => {
          console.error(e);
        });
      }
      htmlText._didTextUpdate = false;
      updateTextBounds(batchableHTMLText, htmlText);
    }
    this._renderer.renderPipes.batch.addToBatch(batchableHTMLText, instructionSet);
  }
  updateRenderable(htmlText) {
    const batchableHTMLText = this._getGpuText(htmlText);
    batchableHTMLText._batcher.updateElement(batchableHTMLText);
  }
  async _updateGpuText(htmlText) {
    htmlText._didTextUpdate = false;
    const batchableHTMLText = this._getGpuText(htmlText);
    if (batchableHTMLText.generatingTexture) return;
    const oldTexturePromise = batchableHTMLText.texturePromise;
    batchableHTMLText.texturePromise = null;
    batchableHTMLText.generatingTexture = true;
    htmlText._resolution = htmlText._autoResolution ? this._renderer.resolution : htmlText.resolution;
    let texturePromise = this._renderer.htmlText.getTexturePromise(htmlText);
    if (oldTexturePromise) {
      texturePromise = texturePromise.finally(() => {
        this._renderer.htmlText.decreaseReferenceCount(batchableHTMLText.currentKey);
        this._renderer.htmlText.returnTexturePromise(oldTexturePromise);
      });
    }
    batchableHTMLText.texturePromise = texturePromise;
    batchableHTMLText.currentKey = htmlText.styleKey;
    batchableHTMLText.texture = await texturePromise;
    const renderGroup = htmlText.renderGroup || htmlText.parentRenderGroup;
    if (renderGroup) {
      renderGroup.structureDidChange = true;
    }
    batchableHTMLText.generatingTexture = false;
    updateTextBounds(batchableHTMLText, htmlText);
  }
  _getGpuText(htmlText) {
    return htmlText._gpuData[this._renderer.uid] || this.initGpuText(htmlText);
  }
  initGpuText(htmlText) {
    const batchableHTMLText = new BatchableHTMLText();
    batchableHTMLText.renderable = htmlText;
    batchableHTMLText.transform = htmlText.groupTransform;
    batchableHTMLText.texture = Texture.EMPTY;
    batchableHTMLText.bounds = { minX: 0, maxX: 1, minY: 0, maxY: 0 };
    batchableHTMLText.roundPixels = this._renderer._roundPixels | htmlText._roundPixels;
    htmlText._resolution = htmlText._autoResolution ? this._renderer.resolution : htmlText.resolution;
    htmlText._gpuData[this._renderer.uid] = batchableHTMLText;
    this._managedTexts.add(htmlText);
    return batchableHTMLText;
  }
  onTextUnload(text) {
    const gpuData = text._gpuData[this._renderer.uid];
    if (!gpuData) return;
    const { htmlText } = this._renderer;
    htmlText.getReferenceCount(gpuData.currentKey) === null ? htmlText.returnTexturePromise(gpuData.texturePromise) : htmlText.decreaseReferenceCount(gpuData.currentKey);
  }
  destroy() {
    this._managedTexts.destroy();
    this._renderer = null;
  }
}
/** @ignore */
HTMLTextPipe.extension = {
  type: [
    ExtensionType.WebGLPipes,
    ExtensionType.WebGPUPipes,
    ExtensionType.CanvasPipes
  ],
  name: "htmlText"
};

export { HTMLTextPipe };
//# sourceMappingURL=HTMLTextPipe.mjs.map
