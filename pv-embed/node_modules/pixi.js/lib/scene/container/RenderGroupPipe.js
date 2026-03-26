'use strict';

var Extensions = require('../../extensions/Extensions.js');
var Matrix = require('../../maths/matrix/Matrix.js');
var PoolGroup = require('../../utils/pool/PoolGroup.js');
var BatchableSprite = require('../sprite/BatchableSprite.js');
var executeInstructions = require('./utils/executeInstructions.js');

"use strict";
class RenderGroupPipe {
  constructor(renderer) {
    this._renderer = renderer;
  }
  addRenderGroup(renderGroup, instructionSet) {
    if (renderGroup.isCachedAsTexture) {
      this._addRenderableCacheAsTexture(renderGroup, instructionSet);
    } else {
      this._addRenderableDirect(renderGroup, instructionSet);
    }
  }
  execute(renderGroup) {
    if (!renderGroup.isRenderable) return;
    if (renderGroup.isCachedAsTexture) {
      this._executeCacheAsTexture(renderGroup);
    } else {
      this._executeDirect(renderGroup);
    }
  }
  destroy() {
    this._renderer = null;
  }
  _addRenderableDirect(renderGroup, instructionSet) {
    this._renderer.renderPipes.batch.break(instructionSet);
    if (renderGroup._batchableRenderGroup) {
      PoolGroup.BigPool.return(renderGroup._batchableRenderGroup);
      renderGroup._batchableRenderGroup = null;
    }
    instructionSet.add(renderGroup);
  }
  _addRenderableCacheAsTexture(renderGroup, instructionSet) {
    const batchableRenderGroup = renderGroup._batchableRenderGroup ?? (renderGroup._batchableRenderGroup = PoolGroup.BigPool.get(BatchableSprite.BatchableSprite));
    batchableRenderGroup.renderable = renderGroup.root;
    batchableRenderGroup.transform = renderGroup.root.relativeGroupTransform;
    batchableRenderGroup.texture = renderGroup.texture;
    batchableRenderGroup.bounds = renderGroup._textureBounds;
    instructionSet.add(renderGroup);
    this._renderer.renderPipes.blendMode.pushBlendMode(renderGroup, renderGroup.root.groupBlendMode, instructionSet);
    this._renderer.renderPipes.batch.addToBatch(batchableRenderGroup, instructionSet);
    this._renderer.renderPipes.blendMode.popBlendMode(instructionSet);
  }
  _executeCacheAsTexture(renderGroup) {
    if (renderGroup.textureNeedsUpdate) {
      renderGroup.textureNeedsUpdate = false;
      const worldTransformMatrix = new Matrix.Matrix().translate(
        -renderGroup._textureBounds.x,
        -renderGroup._textureBounds.y
      );
      this._renderer.renderTarget.push(renderGroup.texture, true, null, renderGroup.texture.frame);
      this._renderer.globalUniforms.push({
        worldTransformMatrix,
        worldColor: 4294967295,
        offset: { x: 0, y: 0 }
      });
      executeInstructions.executeInstructions(renderGroup, this._renderer.renderPipes);
      this._renderer.renderTarget.finishRenderPass();
      this._renderer.renderTarget.pop();
      this._renderer.globalUniforms.pop();
    }
    renderGroup._batchableRenderGroup._batcher.updateElement(renderGroup._batchableRenderGroup);
    renderGroup._batchableRenderGroup._batcher.geometry.buffers[0].update();
  }
  _executeDirect(renderGroup) {
    this._renderer.globalUniforms.push({
      worldTransformMatrix: renderGroup.inverseParentTextureTransform,
      worldColor: renderGroup.worldColorAlpha
    });
    executeInstructions.executeInstructions(renderGroup, this._renderer.renderPipes);
    this._renderer.globalUniforms.pop();
  }
}
RenderGroupPipe.extension = {
  type: [
    Extensions.ExtensionType.WebGLPipes,
    Extensions.ExtensionType.WebGPUPipes,
    Extensions.ExtensionType.CanvasPipes
  ],
  name: "renderGroup"
};

exports.RenderGroupPipe = RenderGroupPipe;
//# sourceMappingURL=RenderGroupPipe.js.map
