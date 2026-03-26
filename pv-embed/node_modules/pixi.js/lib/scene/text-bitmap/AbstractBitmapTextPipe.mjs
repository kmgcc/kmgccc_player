import { Cache } from '../../assets/cache/Cache.mjs';
import { GCManagedHash } from '../../utils/data/GCManagedHash.mjs';
import { Graphics } from '../graphics/shared/Graphics.mjs';
import { CanvasTextMetrics } from '../text/canvas/CanvasTextMetrics.mjs';
import { BitmapFontManager } from './BitmapFontManager.mjs';
import { getBitmapTextLayout } from './utils/getBitmapTextLayout.mjs';

"use strict";
class BitmapTextGraphics extends Graphics {
  destroy() {
    if (this.context.customShader) {
      this.context.customShader.destroy();
    }
    super.destroy();
  }
}
class AbstractBitmapTextPipe {
  constructor(renderer) {
    this._renderer = renderer;
    this._managedBitmapTexts = new GCManagedHash({ renderer, type: "renderable", priority: -2, name: "bitmapText" });
  }
  validateRenderable(bitmapText) {
    const graphicsRenderable = this._getGpuBitmapText(bitmapText);
    return this._renderer.renderPipes.graphics.validateRenderable(graphicsRenderable);
  }
  addRenderable(bitmapText, instructionSet) {
    const graphicsRenderable = this._getGpuBitmapText(bitmapText);
    syncWithProxy(bitmapText, graphicsRenderable);
    if (bitmapText._didTextUpdate) {
      bitmapText._didTextUpdate = false;
      this._updateContext(bitmapText, graphicsRenderable);
    }
    this._renderer.renderPipes.graphics.addRenderable(graphicsRenderable, instructionSet);
    if (graphicsRenderable.context.customShader) {
      this._updateDistanceField(bitmapText);
    }
  }
  updateRenderable(bitmapText) {
    const graphicsRenderable = this._getGpuBitmapText(bitmapText);
    syncWithProxy(bitmapText, graphicsRenderable);
    this._renderer.renderPipes.graphics.updateRenderable(graphicsRenderable);
    if (graphicsRenderable.context.customShader) {
      this._updateDistanceField(bitmapText);
    }
  }
  _updateContext(bitmapText, proxyGraphics) {
    const { context } = proxyGraphics;
    const bitmapFont = BitmapFontManager.getFont(bitmapText.text, bitmapText._style);
    context.clear();
    if (bitmapFont.distanceField.type !== "none") {
      const sdfShader = this.getSdfShader();
      if (sdfShader) {
        if (!context.customShader) {
          context.customShader = sdfShader;
        }
      }
    }
    const chars = CanvasTextMetrics.graphemeSegmenter(bitmapText.text);
    const style = bitmapText._style;
    let currentY = bitmapFont.baseLineOffset;
    const bitmapTextLayout = getBitmapTextLayout(chars, style, bitmapFont, true);
    const padding = style.padding;
    const scale = bitmapTextLayout.scale;
    let tx = bitmapTextLayout.width;
    let ty = bitmapTextLayout.height + bitmapTextLayout.offsetY;
    if (style._stroke) {
      tx += style._stroke.width / scale;
      ty += style._stroke.width / scale;
    }
    context.translate(-bitmapText._anchor._x * tx - padding, -bitmapText._anchor._y * ty - padding).scale(scale, scale);
    const tint = bitmapFont.applyFillAsTint ? style._fill.color : 16777215;
    let fontSize = bitmapFont.fontMetrics.fontSize;
    let lineHeight = bitmapFont.lineHeight;
    if (style.lineHeight) {
      fontSize = style.fontSize / scale;
      lineHeight = style.lineHeight / scale;
    }
    let linePositionYShift = (lineHeight - fontSize) / 2;
    if (linePositionYShift - bitmapFont.baseLineOffset < 0) {
      linePositionYShift = 0;
    }
    for (let i = 0; i < bitmapTextLayout.lines.length; i++) {
      const line = bitmapTextLayout.lines[i];
      for (let j = 0; j < line.charPositions.length; j++) {
        const char = line.chars[j];
        const charData = bitmapFont.chars[char];
        if (charData?.texture) {
          const texture = charData.texture;
          context.texture(
            texture,
            tint,
            Math.round(line.charPositions[j] + charData.xOffset),
            Math.round(currentY + charData.yOffset + linePositionYShift),
            texture.orig.width,
            texture.orig.height
          );
        }
      }
      currentY += lineHeight;
    }
  }
  _getGpuBitmapText(bitmapText) {
    return bitmapText._gpuData[this._renderer.uid] || this.initGpuText(bitmapText);
  }
  initGpuText(bitmapText) {
    const proxyRenderable = new BitmapTextGraphics();
    bitmapText._gpuData[this._renderer.uid] = proxyRenderable;
    this._updateContext(bitmapText, proxyRenderable);
    this._managedBitmapTexts.add(bitmapText);
    return proxyRenderable;
  }
  _updateDistanceField(bitmapText) {
    const context = this._getGpuBitmapText(bitmapText).context;
    const fontFamily = bitmapText._style.fontFamily;
    const dynamicFont = Cache.get(`${fontFamily}-bitmap`);
    const { a, b, c, d } = bitmapText.groupTransform;
    const dx = Math.sqrt(a * a + b * b);
    const dy = Math.sqrt(c * c + d * d);
    const worldScale = (Math.abs(dx) + Math.abs(dy)) / 2;
    const fontScale = dynamicFont.baseRenderedFontSize / bitmapText._style.fontSize;
    const distance = worldScale * dynamicFont.distanceField.range * (1 / fontScale);
    context.customShader.resources.localUniforms.uniforms.uDistance = distance;
  }
  destroy() {
    this._managedBitmapTexts.destroy();
    this._renderer = null;
    this._managedBitmapTexts = null;
  }
}
function syncWithProxy(container, proxy) {
  proxy.groupTransform = container.groupTransform;
  proxy.groupColorAlpha = container.groupColorAlpha;
  proxy.groupColor = container.groupColor;
  proxy.groupBlendMode = container.groupBlendMode;
  proxy.globalDisplayStatus = container.globalDisplayStatus;
  proxy.groupTransform = container.groupTransform;
  proxy.localDisplayStatus = container.localDisplayStatus;
  proxy.groupAlpha = container.groupAlpha;
  proxy._roundPixels = container._roundPixels;
}

export { AbstractBitmapTextPipe, BitmapTextGraphics };
//# sourceMappingURL=AbstractBitmapTextPipe.mjs.map
