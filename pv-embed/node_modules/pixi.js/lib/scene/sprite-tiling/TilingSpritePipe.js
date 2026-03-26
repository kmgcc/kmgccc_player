'use strict';

var Extensions = require('../../extensions/Extensions.js');
var getAdjustedBlendModeBlend = require('../../rendering/renderers/shared/state/getAdjustedBlendModeBlend.js');
var State = require('../../rendering/renderers/shared/state/State.js');
var types = require('../../rendering/renderers/types.js');
var GCManagedHash = require('../../utils/data/GCManagedHash.js');
var colorToUniform = require('../graphics/gpu/colorToUniform.js');
var BatchableMesh = require('../mesh/shared/BatchableMesh.js');
var MeshGeometry = require('../mesh/shared/MeshGeometry.js');
var TilingSpriteShader = require('./shader/TilingSpriteShader.js');
var QuadGeometry = require('./utils/QuadGeometry.js');
var setPositions = require('./utils/setPositions.js');
var setUvs = require('./utils/setUvs.js');

"use strict";
const sharedQuad = new QuadGeometry.QuadGeometry();
class TilingSpriteGpuData {
  constructor() {
    this.canBatch = true;
    this.geometry = new MeshGeometry.MeshGeometry({
      indices: sharedQuad.indices.slice(),
      positions: sharedQuad.positions.slice(),
      uvs: sharedQuad.uvs.slice()
    });
  }
  destroy() {
    this.geometry.destroy();
    this.shader?.destroy();
  }
}
class TilingSpritePipe {
  constructor(renderer) {
    this._state = State.State.default2d;
    this._renderer = renderer;
    this._managedTilingSprites = new GCManagedHash.GCManagedHash({ renderer, type: "renderable", name: "tilingSprite" });
  }
  validateRenderable(renderable) {
    const tilingSpriteData = this._getTilingSpriteData(renderable);
    const couldBatch = tilingSpriteData.canBatch;
    this._updateCanBatch(renderable);
    const canBatch = tilingSpriteData.canBatch;
    if (canBatch && canBatch === couldBatch) {
      const { batchableMesh } = tilingSpriteData;
      return !batchableMesh._batcher.checkAndUpdateTexture(
        batchableMesh,
        renderable.texture
      );
    }
    return couldBatch !== canBatch;
  }
  addRenderable(tilingSprite, instructionSet) {
    const batcher = this._renderer.renderPipes.batch;
    this._updateCanBatch(tilingSprite);
    const tilingSpriteData = this._getTilingSpriteData(tilingSprite);
    const { geometry, canBatch } = tilingSpriteData;
    if (canBatch) {
      tilingSpriteData.batchableMesh || (tilingSpriteData.batchableMesh = new BatchableMesh.BatchableMesh());
      const batchableMesh = tilingSpriteData.batchableMesh;
      if (tilingSprite.didViewUpdate) {
        this._updateBatchableMesh(tilingSprite);
        batchableMesh.geometry = geometry;
        batchableMesh.renderable = tilingSprite;
        batchableMesh.transform = tilingSprite.groupTransform;
        batchableMesh.setTexture(tilingSprite._texture);
      }
      batchableMesh.roundPixels = this._renderer._roundPixels | tilingSprite._roundPixels;
      batcher.addToBatch(batchableMesh, instructionSet);
    } else {
      batcher.break(instructionSet);
      tilingSpriteData.shader || (tilingSpriteData.shader = new TilingSpriteShader.TilingSpriteShader());
      this.updateRenderable(tilingSprite);
      instructionSet.add(tilingSprite);
    }
  }
  execute(tilingSprite) {
    const renderer = this._renderer;
    const { shader } = this._getTilingSpriteData(tilingSprite);
    shader.groups[0] = renderer.globalUniforms.bindGroup;
    const localUniforms = shader.resources.localUniforms.uniforms;
    localUniforms.uTransformMatrix = tilingSprite.groupTransform;
    localUniforms.uRound = renderer._roundPixels | tilingSprite._roundPixels;
    colorToUniform.color32BitToUniform(
      tilingSprite.groupColorAlpha,
      localUniforms.uColor,
      0
    );
    this._state.blendMode = getAdjustedBlendModeBlend.getAdjustedBlendModeBlend(tilingSprite.groupBlendMode, tilingSprite.texture._source);
    renderer.encoder.draw({
      geometry: sharedQuad,
      shader,
      state: this._state
    });
  }
  updateRenderable(tilingSprite) {
    const tilingSpriteData = this._getTilingSpriteData(tilingSprite);
    const { canBatch } = tilingSpriteData;
    if (canBatch) {
      const { batchableMesh } = tilingSpriteData;
      if (tilingSprite.didViewUpdate) this._updateBatchableMesh(tilingSprite);
      batchableMesh._batcher.updateElement(batchableMesh);
    } else if (tilingSprite.didViewUpdate) {
      const { shader } = tilingSpriteData;
      shader.updateUniforms(
        tilingSprite.width,
        tilingSprite.height,
        tilingSprite._tileTransform.matrix,
        tilingSprite.anchor.x,
        tilingSprite.anchor.y,
        tilingSprite.texture
      );
    }
  }
  _getTilingSpriteData(renderable) {
    return renderable._gpuData[this._renderer.uid] || this._initTilingSpriteData(renderable);
  }
  _initTilingSpriteData(tilingSprite) {
    const gpuData = new TilingSpriteGpuData();
    gpuData.renderable = tilingSprite;
    tilingSprite._gpuData[this._renderer.uid] = gpuData;
    this._managedTilingSprites.add(tilingSprite);
    return gpuData;
  }
  _updateBatchableMesh(tilingSprite) {
    const renderableData = this._getTilingSpriteData(tilingSprite);
    const { geometry } = renderableData;
    const style = tilingSprite.texture.source.style;
    if (style.addressMode !== "repeat") {
      style.addressMode = "repeat";
      style.update();
    }
    setUvs.setUvs(tilingSprite, geometry.uvs);
    setPositions.setPositions(tilingSprite, geometry.positions);
  }
  destroy() {
    this._managedTilingSprites.destroy();
    this._renderer = null;
  }
  _updateCanBatch(tilingSprite) {
    const renderableData = this._getTilingSpriteData(tilingSprite);
    const texture = tilingSprite.texture;
    let _nonPowOf2wrapping = true;
    if (this._renderer.type === types.RendererType.WEBGL) {
      _nonPowOf2wrapping = this._renderer.context.supports.nonPowOf2wrapping;
    }
    renderableData.canBatch = texture.textureMatrix.isSimple && (_nonPowOf2wrapping || texture.source.isPowerOfTwo);
    return renderableData.canBatch;
  }
}
/** @ignore */
TilingSpritePipe.extension = {
  type: [
    Extensions.ExtensionType.WebGLPipes,
    Extensions.ExtensionType.WebGPUPipes
  ],
  name: "tilingSprite"
};

exports.TilingSpriteGpuData = TilingSpriteGpuData;
exports.TilingSpritePipe = TilingSpritePipe;
//# sourceMappingURL=TilingSpritePipe.js.map
