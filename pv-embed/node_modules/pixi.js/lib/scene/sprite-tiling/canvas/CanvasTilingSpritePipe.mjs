import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { Matrix } from '../../../maths/matrix/Matrix.mjs';
import { Point } from '../../../maths/point/Point.mjs';
import { canvasUtils } from '../../../rendering/renderers/canvas/utils/canvasUtils.mjs';
import { bgr2rgb } from '../../container/container-mixins/getGlobalMixin.mjs';
import { multiplyHexColors } from '../../container/utils/multiplyHexColors.mjs';

"use strict";
const worldMatrix = new Matrix();
const patternMatrix = new Matrix();
const patternRect = [new Point(), new Point(), new Point(), new Point()];
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
    const tint = bgr2rgb(multiplyHexColors(groupTintBGR, globalTint));
    const texture = tilingSprite.texture;
    const pattern = canvasUtils.getTintedPattern(texture, tint);
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
    ExtensionType.CanvasPipes
  ],
  name: "tilingSprite"
};

export { CanvasTilingSpritePipe };
//# sourceMappingURL=CanvasTilingSpritePipe.mjs.map
