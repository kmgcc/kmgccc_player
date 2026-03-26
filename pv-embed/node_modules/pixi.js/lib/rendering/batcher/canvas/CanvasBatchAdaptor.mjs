import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { groupD8 } from '../../../maths/matrix/groupD8.mjs';
import { Matrix } from '../../../maths/matrix/Matrix.mjs';
import { bgr2rgb } from '../../../scene/container/container-mixins/getGlobalMixin.mjs';
import { multiplyHexColors } from '../../../scene/container/utils/multiplyHexColors.mjs';
import { canvasUtils } from '../../renderers/canvas/utils/canvasUtils.mjs';

"use strict";
const _CanvasBatchAdaptor = class _CanvasBatchAdaptor {
  static _getPatternRepeat(addressModeU, addressModeV) {
    const repeatU = addressModeU && addressModeU !== "clamp-to-edge";
    const repeatV = addressModeV && addressModeV !== "clamp-to-edge";
    if (repeatU && repeatV) return "repeat";
    if (repeatU) return "repeat-x";
    if (repeatV) return "repeat-y";
    return "no-repeat";
  }
  start(batchPipe, geometry, shader) {
    void batchPipe;
    void geometry;
    void shader;
  }
  execute(batchPipe, batch) {
    const elements = batch.elements;
    if (!elements || !elements.length) return;
    const renderer = batchPipe.renderer;
    const contextSystem = renderer.canvasContext;
    const context = contextSystem.activeContext;
    for (let i = 0; i < elements.length; i++) {
      const element = elements[i];
      if (!element.packAsQuad) continue;
      const quad = element;
      const texture = quad.texture;
      const source = texture ? canvasUtils.getCanvasSource(texture) : null;
      if (!source) continue;
      const textureStyle = texture.source.style;
      const smoothProperty = contextSystem.smoothProperty;
      const shouldSmooth = textureStyle.scaleMode !== "nearest";
      if (context[smoothProperty] !== shouldSmooth) {
        context[smoothProperty] = shouldSmooth;
      }
      contextSystem.setBlendMode(batch.blendMode);
      const globalColor = renderer.globalUniforms.globalUniformData?.worldColor ?? 4294967295;
      const argb = quad.color;
      const globalAlpha = (globalColor >>> 24 & 255) / 255;
      const quadAlpha = (argb >>> 24 & 255) / 255;
      const filterAlpha = renderer.filter?.alphaMultiplier ?? 1;
      const alpha = globalAlpha * quadAlpha * filterAlpha;
      if (alpha <= 0) continue;
      context.globalAlpha = alpha;
      const globalTint = globalColor & 16777215;
      const quadTint = argb & 16777215;
      const tint = bgr2rgb(multiplyHexColors(quadTint, globalTint));
      const frame = texture.frame;
      const repeatU = textureStyle.addressModeU ?? textureStyle.addressMode;
      const repeatV = textureStyle.addressModeV ?? textureStyle.addressMode;
      const repeat = _CanvasBatchAdaptor._getPatternRepeat(repeatU, repeatV);
      const resolution = texture.source._resolution ?? texture.source.resolution ?? 1;
      const isFromCachedRenderGroup = quad.renderable?.renderGroup?.isCachedAsTexture;
      const sx = frame.x * resolution;
      const sy = frame.y * resolution;
      const sw = frame.width * resolution;
      const sh = frame.height * resolution;
      const bounds = quad.bounds;
      const isRootTarget = renderer.renderTarget.renderTarget.isRoot;
      const dx = bounds.minX;
      const dy = bounds.minY;
      const dw = bounds.maxX - bounds.minX;
      const dh = bounds.maxY - bounds.minY;
      const rotate = texture.rotate;
      const uvs = texture.uvs;
      const uvMin = Math.min(uvs.x0, uvs.x1, uvs.x2, uvs.x3, uvs.y0, uvs.y1, uvs.y2, uvs.y3);
      const uvMax = Math.max(uvs.x0, uvs.x1, uvs.x2, uvs.x3, uvs.y0, uvs.y1, uvs.y2, uvs.y3);
      const needsRepeat = repeat !== "no-repeat" && (uvMin < 0 || uvMax > 1);
      const willUseProcessedCanvas = !needsRepeat && (tint !== 16777215 || rotate);
      const applyRotateTransform = rotate && !willUseProcessedCanvas;
      if (applyRotateTransform) {
        _CanvasBatchAdaptor._tempPatternMatrix.copyFrom(quad.transform);
        groupD8.matrixAppendRotationInv(
          _CanvasBatchAdaptor._tempPatternMatrix,
          rotate,
          dx,
          dy,
          dw,
          dh
        );
        contextSystem.setContextTransform(
          _CanvasBatchAdaptor._tempPatternMatrix,
          quad.roundPixels === 1,
          void 0,
          isFromCachedRenderGroup && isRootTarget
        );
      } else {
        contextSystem.setContextTransform(
          quad.transform,
          quad.roundPixels === 1,
          void 0,
          isFromCachedRenderGroup && isRootTarget
        );
      }
      const drawX = applyRotateTransform ? 0 : dx;
      const drawY = applyRotateTransform ? 0 : dy;
      const drawW = dw;
      const drawH = dh;
      if (needsRepeat) {
        let patternSource = source;
        const canTint = tint !== 16777215 && !rotate;
        const fitsFrame = frame.width <= texture.source.width && frame.height <= texture.source.height;
        if (canTint && fitsFrame) {
          patternSource = canvasUtils.getTintedCanvas({ texture }, tint);
        }
        const pattern = context.createPattern(patternSource, repeat);
        if (!pattern) continue;
        const denomX = drawW;
        const denomY = drawH;
        if (denomX === 0 || denomY === 0) continue;
        const invDx = 1 / denomX;
        const invDy = 1 / denomY;
        const a = (uvs.x1 - uvs.x0) * invDx;
        const b = (uvs.y1 - uvs.y0) * invDx;
        const c = (uvs.x3 - uvs.x0) * invDy;
        const d = (uvs.y3 - uvs.y0) * invDy;
        const tx = uvs.x0 - a * drawX - c * drawY;
        const ty = uvs.y0 - b * drawX - d * drawY;
        const pixelWidth = texture.source.pixelWidth;
        const pixelHeight = texture.source.pixelHeight;
        _CanvasBatchAdaptor._tempPatternMatrix.set(
          a * pixelWidth,
          b * pixelHeight,
          c * pixelWidth,
          d * pixelHeight,
          tx * pixelWidth,
          ty * pixelHeight
        );
        canvasUtils.applyPatternTransform(pattern, _CanvasBatchAdaptor._tempPatternMatrix);
        context.fillStyle = pattern;
        context.fillRect(drawX, drawY, drawW, drawH);
      } else {
        const needsProcessing = tint !== 16777215 || rotate;
        const processedSource = needsProcessing ? canvasUtils.getTintedCanvas({ texture }, tint) : source;
        const isProcessed = processedSource !== source;
        context.drawImage(
          processedSource,
          isProcessed ? 0 : sx,
          isProcessed ? 0 : sy,
          isProcessed ? processedSource.width : sw,
          isProcessed ? processedSource.height : sh,
          drawX,
          drawY,
          drawW,
          drawH
        );
      }
    }
  }
};
_CanvasBatchAdaptor._tempPatternMatrix = new Matrix();
/** @ignore */
_CanvasBatchAdaptor.extension = {
  type: [
    ExtensionType.CanvasPipesAdaptor
  ],
  name: "batch"
};
let CanvasBatchAdaptor = _CanvasBatchAdaptor;

export { CanvasBatchAdaptor };
//# sourceMappingURL=CanvasBatchAdaptor.mjs.map
