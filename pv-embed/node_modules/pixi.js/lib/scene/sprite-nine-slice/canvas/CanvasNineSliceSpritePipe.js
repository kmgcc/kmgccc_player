'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var canvasUtils = require('../../../rendering/renderers/canvas/utils/canvasUtils.js');
var getGlobalMixin = require('../../container/container-mixins/getGlobalMixin.js');
var multiplyHexColors = require('../../container/utils/multiplyHexColors.js');

"use strict";
class CanvasNineSliceSpritePipe {
  constructor(renderer) {
    this._renderer = renderer;
  }
  validateRenderable(_sprite) {
    return false;
  }
  addRenderable(sprite, instructionSet) {
    this._renderer.renderPipes.batch.break(instructionSet);
    instructionSet.add(sprite);
  }
  updateRenderable(_sprite) {
  }
  execute(sprite) {
    const renderer = this._renderer;
    const contextSystem = renderer.canvasContext;
    const context = contextSystem.activeContext;
    context.save();
    const transform = sprite.groupTransform;
    const roundPixels = renderer._roundPixels | sprite._roundPixels;
    contextSystem.setContextTransform(transform, roundPixels === 1);
    contextSystem.setBlendMode(sprite.groupBlendMode);
    const globalColor = renderer.globalUniforms.globalUniformData?.worldColor ?? 4294967295;
    const groupColorAlpha = sprite.groupColorAlpha;
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
    const texture = sprite.texture;
    const drawSource = canvasUtils.canvasUtils.getCanvasSource(texture);
    if (!drawSource) {
      context.restore();
      return;
    }
    const smoothProperty = contextSystem.smoothProperty;
    const shouldSmooth = texture.source.style.scaleMode !== "nearest";
    if (context[smoothProperty] !== shouldSmooth) {
      context[smoothProperty] = shouldSmooth;
    }
    const needsProcessing = tint !== 16777215 || texture.rotate !== 0;
    const finalSource = needsProcessing ? canvasUtils.canvasUtils.getTintedCanvas({ texture }, tint) : drawSource;
    const {
      leftWidth,
      topHeight,
      rightWidth,
      bottomHeight,
      width,
      height
    } = sprite;
    const totalBorderWidth = leftWidth + rightWidth;
    const totalBorderHeight = topHeight + bottomHeight;
    const scale = Math.min(
      totalBorderWidth > width ? width / totalBorderWidth : 1,
      totalBorderHeight > height ? height / totalBorderHeight : 1,
      1
    );
    const destLeftWidth = leftWidth * scale;
    const destRightWidth = rightWidth * scale;
    const destTopHeight = topHeight * scale;
    const destBottomHeight = bottomHeight * scale;
    const destCenterWidth = Math.max(0, width - destLeftWidth - destRightWidth);
    const destCenterHeight = Math.max(0, height - destTopHeight - destBottomHeight);
    const anchor = sprite.anchor;
    const resolution = texture.source._resolution ?? texture.source.resolution ?? 1;
    let sx = texture.frame.x * resolution;
    let sy = texture.frame.y * resolution;
    const dx = -anchor.x * width;
    const dy = -anchor.y * height;
    const lw = leftWidth * resolution;
    const tw = topHeight * resolution;
    const rw = rightWidth * resolution;
    const bw = bottomHeight * resolution;
    let sw = texture.frame.width * resolution;
    let sh = texture.frame.height * resolution;
    if (needsProcessing) {
      sx = 0;
      sy = 0;
      sw = finalSource.width;
      sh = finalSource.height;
    }
    context.drawImage(finalSource, sx, sy, lw, tw, dx, dy, destLeftWidth, destTopHeight);
    context.drawImage(
      finalSource,
      sx + lw,
      sy,
      sw - lw - rw,
      tw,
      dx + destLeftWidth,
      dy,
      destCenterWidth,
      destTopHeight
    );
    context.drawImage(
      finalSource,
      sx + sw - rw,
      sy,
      rw,
      tw,
      dx + width - destRightWidth,
      dy,
      destRightWidth,
      destTopHeight
    );
    context.drawImage(
      finalSource,
      sx,
      sy + tw,
      lw,
      sh - tw - bw,
      dx,
      dy + destTopHeight,
      destLeftWidth,
      destCenterHeight
    );
    context.drawImage(
      finalSource,
      sx + lw,
      sy + tw,
      sw - lw - rw,
      sh - tw - bw,
      dx + destLeftWidth,
      dy + destTopHeight,
      destCenterWidth,
      destCenterHeight
    );
    context.drawImage(
      finalSource,
      sx + sw - rw,
      sy + tw,
      rw,
      sh - tw - bw,
      dx + width - destRightWidth,
      dy + destTopHeight,
      destRightWidth,
      destCenterHeight
    );
    context.drawImage(
      finalSource,
      sx,
      sy + sh - bw,
      lw,
      bw,
      dx,
      dy + height - destBottomHeight,
      destLeftWidth,
      destBottomHeight
    );
    context.drawImage(
      finalSource,
      sx + lw,
      sy + sh - bw,
      sw - lw - rw,
      bw,
      dx + destLeftWidth,
      dy + height - destBottomHeight,
      destCenterWidth,
      destBottomHeight
    );
    context.drawImage(
      finalSource,
      sx + sw - rw,
      sy + sh - bw,
      rw,
      bw,
      dx + width - destRightWidth,
      dy + height - destBottomHeight,
      destRightWidth,
      destBottomHeight
    );
    context.restore();
  }
  destroy() {
    this._renderer = null;
  }
}
/** @ignore */
CanvasNineSliceSpritePipe.extension = {
  type: [
    Extensions.ExtensionType.CanvasPipes
  ],
  name: "nineSliceSprite"
};

exports.CanvasNineSliceSpritePipe = CanvasNineSliceSpritePipe;
//# sourceMappingURL=CanvasNineSliceSpritePipe.js.map
