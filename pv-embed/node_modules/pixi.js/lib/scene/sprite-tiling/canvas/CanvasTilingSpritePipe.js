'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var Matrix = require('../../../maths/matrix/Matrix.js');
var Point = require('../../../maths/point/Point.js');
var canvasUtils = require('../../../rendering/renderers/canvas/utils/canvasUtils.js');
var getGlobalMixin = require('../../container/container-mixins/getGlobalMixin.js');
var multiplyHexColors = require('../../container/utils/multiplyHexColors.js');

"use strict";
const worldMatrix = new Matrix.Matrix();
const patternMatrix = new Matrix.Matrix();
const patternRect = [new Point.Point(), new Point.Point(), new Point.Point(), new Point.Point()];
class CanvasTilingSpritePipe {
  constructor(renderer) {
    this._renderer = renderer;
  }
  validateRenderable(_renderable) {
    return false;
  }
  addRenderable(tilingSprite, instructionSet) {
    this._renderer.renderPipes.batch.break(instructionSet);
    instructionSet.add(tilingSprite);
  }
  updateRenderable(_tilingSprite) {
  }
  execute(tilingSprite) {
    const renderer = this._renderer;
    const contextSystem = renderer.canvasContext;
    const context = contextSystem.activeContext;
    context.save();
    contextSystem.setBlendMode(tilingSprite.groupBlendMode);
    const globalColor = renderer.globalUniforms.globalUniformData?.worldColor ?? 4294967295;
    const groupColorAlpha = tilingSprite.groupColorAlpha;
    const globalAlpha = (globalColor >>> 24 & 255) / 255;
    const groupAlphaValue = (groupColorAlpha >>> 24 & 255) / 255;
    const filterAlpha = renderer.filter?.alphaMultiplier ?? 1;
    const alpha = globalAlpha * groupAlphaValue * filterAlpha;
    if (alpha <= 0) {
      context.restore();
      return;
    }
    context.globalAlpha = alpha;
    const globalTint = globalColor & 16777215;
    const groupTintBGR = groupColorAlpha & 16777215;
    const tint = getGlobalMixin.bgr2rgb(multiplyHexColors.multiplyHexColors(groupTintBGR, globalTint));
    const texture = tilingSprite.texture;
    const pattern = canvasUtils.canvasUtils.getTintedPattern(texture, tint);
    const width = tilingSprite.width;
    const height = tilingSprite.height;
    const transform = tilingSprite.groupTransform;
    const resolution = texture.source._resolution ?? texture.source.resolution ?? 1;
    patternMatrix.copyFrom(tilingSprite._tileTransform.matrix);
    if (!tilingSprite.applyAnchorToTexture) {
      patternMatrix.translate(-tilingSprite.anchor.x * width, -tilingSprite.anchor.y * height);
    }
    patternMatrix.scale(1 / resolution, 1 / resolution);
    worldMatrix.identity();
    worldMatrix.prepend(patternMatrix);
    worldMatrix.prepend(transform);
    const roundPixels = renderer._roundPixels | tilingSprite._roundPixels;
    contextSystem.setContextTransform(worldMatrix, roundPixels === 1);
    context.fillStyle = pattern;
    const lx = tilingSprite.anchor.x * -width;
    const ly = tilingSprite.anchor.y * -height;
    patternRect[0].set(lx, ly);
    patternRect[1].set(lx + width, ly);
    patternRect[2].set(lx + width, ly + height);
    patternRect[3].set(lx, ly + height);
    for (let i = 0; i < 4; i++) {
      patternMatrix.applyInverse(patternRect[i], patternRect[i]);
    }
    context.beginPath();
    context.moveTo(patternRect[0].x, patternRect[0].y);
    for (let i = 1; i < 4; i++) {
      context.lineTo(patternRect[i].x, patternRect[i].y);
    }
    context.closePath();
    context.fill();
    context.restore();
  }
  destroy() {
    this._renderer = null;
  }
}
/** @ignore */
CanvasTilingSpritePipe.extension = {
  type: [
    Extensions.ExtensionType.CanvasPipes
  ],
  name: "tilingSprite"
};

exports.CanvasTilingSpritePipe = CanvasTilingSpritePipe;
//# sourceMappingURL=CanvasTilingSpritePipe.js.map
