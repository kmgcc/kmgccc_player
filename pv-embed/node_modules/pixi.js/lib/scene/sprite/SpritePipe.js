'use strict';

var Extensions = require('../../extensions/Extensions.js');
var BatchableSprite = require('./BatchableSprite.js');

"use strict";
class SpritePipe {
  constructor(renderer) {
    this._renderer = renderer;
  }
  addRenderable(sprite, instructionSet) {
    const gpuSprite = this._getGpuSprite(sprite);
    if (sprite.didViewUpdate) this._updateBatchableSprite(sprite, gpuSprite);
    this._renderer.renderPipes.batch.addToBatch(gpuSprite, instructionSet);
  }
  updateRenderable(sprite) {
    const gpuSprite = this._getGpuSprite(sprite);
    if (sprite.didViewUpdate) this._updateBatchableSprite(sprite, gpuSprite);
    gpuSprite._batcher.updateElement(gpuSprite);
  }
  validateRenderable(sprite) {
    const gpuSprite = this._getGpuSprite(sprite);
    return !gpuSprite._batcher.checkAndUpdateTexture(
      gpuSprite,
      sprite._texture
    );
  }
  _updateBatchableSprite(sprite, batchableSprite) {
    batchableSprite.bounds = sprite.visualBounds;
    batchableSprite.texture = sprite._texture;
  }
  _getGpuSprite(sprite) {
    return sprite._gpuData[this._renderer.uid] || this._initGPUSprite(sprite);
  }
  _initGPUSprite(sprite) {
    const batchableSprite = new BatchableSprite.BatchableSprite();
    batchableSprite.renderable = sprite;
    batchableSprite.transform = sprite.groupTransform;
    batchableSprite.texture = sprite._texture;
    batchableSprite.bounds = sprite.visualBounds;
    batchableSprite.roundPixels = this._renderer._roundPixels | sprite._roundPixels;
    sprite._gpuData[this._renderer.uid] = batchableSprite;
    return batchableSprite;
  }
  destroy() {
    this._renderer = null;
  }
}
/** @ignore */
SpritePipe.extension = {
  type: [
    Extensions.ExtensionType.WebGLPipes,
    Extensions.ExtensionType.WebGPUPipes,
    Extensions.ExtensionType.CanvasPipes
  ],
  name: "sprite"
};

exports.SpritePipe = SpritePipe;
//# sourceMappingURL=SpritePipe.js.map
