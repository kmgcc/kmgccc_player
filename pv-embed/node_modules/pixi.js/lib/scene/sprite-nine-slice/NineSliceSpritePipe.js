'use strict';

var Extensions = require('../../extensions/Extensions.js');
var GCManagedHash = require('../../utils/data/GCManagedHash.js');
var BatchableMesh = require('../mesh/shared/BatchableMesh.js');
var NineSliceGeometry = require('./NineSliceGeometry.js');

"use strict";
class NineSliceSpriteGpuData extends BatchableMesh.BatchableMesh {
  constructor() {
    super();
    this.geometry = new NineSliceGeometry.NineSliceGeometry();
  }
  destroy() {
    this.geometry.destroy();
  }
}
class NineSliceSpritePipe {
  constructor(renderer) {
    this._renderer = renderer;
    this._managedSprites = new GCManagedHash.GCManagedHash({ renderer, type: "renderable", name: "nineSliceSprite" });
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
    batchableSprite.geometry.update(sprite);
    batchableSprite.setTexture(sprite._texture);
  }
  _getGpuSprite(sprite) {
    return sprite._gpuData[this._renderer.uid] || this._initGPUSprite(sprite);
  }
  _initGPUSprite(sprite) {
    const gpuData = sprite._gpuData[this._renderer.uid] = new NineSliceSpriteGpuData();
    const batchableMesh = gpuData;
    batchableMesh.renderable = sprite;
    batchableMesh.transform = sprite.groupTransform;
    batchableMesh.texture = sprite._texture;
    batchableMesh.roundPixels = this._renderer._roundPixels | sprite._roundPixels;
    this._managedSprites.add(sprite);
    if (!sprite.didViewUpdate) {
      this._updateBatchableSprite(sprite, batchableMesh);
    }
    return gpuData;
  }
  destroy() {
    this._managedSprites.destroy();
    this._renderer = null;
  }
}
/** @ignore */
NineSliceSpritePipe.extension = {
  type: [
    Extensions.ExtensionType.WebGLPipes,
    Extensions.ExtensionType.WebGPUPipes
  ],
  name: "nineSliceSprite"
};

exports.NineSliceSpriteGpuData = NineSliceSpriteGpuData;
exports.NineSliceSpritePipe = NineSliceSpritePipe;
//# sourceMappingURL=NineSliceSpritePipe.js.map
