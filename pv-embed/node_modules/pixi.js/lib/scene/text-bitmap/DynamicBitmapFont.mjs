import { Color } from '../../color/Color.mjs';
import { Rectangle } from '../../maths/shapes/Rectangle.mjs';
import { CanvasPool } from '../../rendering/renderers/shared/texture/CanvasPool.mjs';
import { ImageSource } from '../../rendering/renderers/shared/texture/sources/ImageSource.mjs';
import { Texture } from '../../rendering/renderers/shared/texture/Texture.mjs';
import { TextureStyle } from '../../rendering/renderers/shared/texture/TextureStyle.mjs';
import { deprecation, v8_0_0 } from '../../utils/logging/deprecation.mjs';
import { CanvasTextMetrics } from '../text/canvas/CanvasTextMetrics.mjs';
import { fontStringFromTextStyle } from '../text/canvas/utils/fontStringFromTextStyle.mjs';
import { getCanvasFillStyle } from '../text/canvas/utils/getCanvasFillStyle.mjs';
import { TextStyle } from '../text/TextStyle.mjs';
import { AbstractBitmapFont } from './AbstractBitmapFont.mjs';

"use strict";
const _DynamicBitmapFont = class _DynamicBitmapFont extends AbstractBitmapFont {
  /**
   * @param options - The options for the dynamic bitmap font.
   */
  constructor(options) {
    super();
    /**
     * this is a resolution modifier for the font size..
     * texture resolution will also be used to scale texture according to its font size also
     */
    this.resolution = 1;
    /** The pages of the font. */
    this.pages = [];
    this._padding = 0;
    this._measureCache = /* @__PURE__ */ Object.create(null);
    this._currentChars = [];
    this._currentX = 0;
    this._currentY = 0;
    this._currentMaxCharHeight = 0;
    this._currentPageIndex = -1;
    this._skipKerning = false;
    const dynamicOptions = { ..._DynamicBitmapFont.defaultOptions, ...options };
    this._textureSize = dynamicOptions.textureSize;
    this._mipmap = dynamicOptions.mipmap;
    const style = dynamicOptions.style.clone();
    if (dynamicOptions.overrideFill) {
      style._fill.color = 16777215;
      style._fill.alpha = 1;
      style._fill.texture = Texture.WHITE;
      style._fill.fill = null;
    }
    this.applyFillAsTint = dynamicOptions.overrideFill;
    const requestedFontSize = style.fontSize;
    style.fontSize = this.baseMeasurementFontSize;
    const font = fontStringFromTextStyle(style);
    if (dynamicOptions.overrideSize) {
      if (style._stroke) {
        style._stroke.width *= this.baseRenderedFontSize / requestedFontSize;
      }
      if (style.dropShadow) {
        style.dropShadow.blur *= this.baseRenderedFontSize / requestedFontSize;
        style.dropShadow.distance *= this.baseRenderedFontSize / requestedFontSize;
      }
    } else {
      style.fontSize = this.baseRenderedFontSize = requestedFontSize;
    }
    this._style = style;
    this._skipKerning = dynamicOptions.skipKerning ?? false;
    this.resolution = dynamicOptions.resolution ?? 1;
    this._padding = dynamicOptions.padding ?? 4;
    if (dynamicOptions.textureStyle) {
      this._textureStyle = dynamicOptions.textureStyle instanceof TextureStyle ? dynamicOptions.textureStyle : new TextureStyle(dynamicOptions.textureStyle);
    }
    this.fontMetrics = CanvasTextMetrics.measureFont(font);
    this.lineHeight = style.lineHeight || this.fontMetrics.fontSize || style.fontSize;
  }
  ensureCharacters(chars) {
    const charList = CanvasTextMetrics.graphemeSegmenter(chars).filter((char) => !this._currentChars.includes(char)).filter((char, index, self) => self.indexOf(char) === index);
    if (!charList.length) return;
    this._currentChars = [...this._currentChars, ...charList];
    let pageData;
    if (this._currentPageIndex === -1) {
      pageData = this._nextPage();
    } else {
      pageData = this.pages[this._currentPageIndex];
    }
    let { canvas, context } = pageData.canvasAndContext;
    let textureSource = pageData.texture.source;
    const style = this._style;
    let currentX = this._currentX;
    let currentY = this._currentY;
    let currentMaxCharHeight = this._currentMaxCharHeight;
    const fontScale = this.baseRenderedFontSize / this.baseMeasurementFontSize;
    const extraPadding = (style.dropShadow?.distance ?? 0) + (style._stroke?.width ?? 0);
    const padding = this._padding + extraPadding;
    let skipTexture = false;
    const maxTextureWidth = canvas.width / this.resolution;
    const maxTextureHeight = canvas.height / this.resolution;
    for (let i = 0; i < charList.length; i++) {
      const char = charList[i];
      const metrics = CanvasTextMetrics.measureText(char, style, canvas, false);
      metrics.lineHeight = metrics.height;
      const width = metrics.width * fontScale;
      const textureGlyphWidth = Math.ceil((style.fontStyle === "italic" ? 2 : 1) * width);
      const height = metrics.height * fontScale;
      const paddedWidth = textureGlyphWidth + padding * 2;
      const paddedHeight = height + padding * 2;
      skipTexture = false;
      if (char !== "\n" && char !== "\r" && char !== "	" && char !== " ") {
        skipTexture = true;
        currentMaxCharHeight = Math.ceil(Math.max(paddedHeight, currentMaxCharHeight));
      }
      if (currentX + paddedWidth > maxTextureWidth) {
        currentY += currentMaxCharHeight;
        currentMaxCharHeight = paddedHeight;
        currentX = 0;
        if (currentY + currentMaxCharHeight > maxTextureHeight) {
          textureSource.update();
          const pageData2 = this._nextPage();
          canvas = pageData2.canvasAndContext.canvas;
          context = pageData2.canvasAndContext.context;
          textureSource = pageData2.texture.source;
          currentX = 0;
          currentY = 0;
          currentMaxCharHeight = 0;
        }
      }
      const xAdvance = context.measureText(char).width / fontScale;
      this.chars[char] = {
        id: char.codePointAt(0),
        xOffset: -(padding / fontScale),
        yOffset: -(padding / fontScale),
        xAdvance,
        kerning: {}
      };
      if (skipTexture) {
        this._drawGlyph(
          context,
          metrics,
          currentX + padding,
          currentY + padding,
          fontScale,
          style
        );
        const px = textureSource.width * fontScale;
        const py = textureSource.height * fontScale;
        const frame = new Rectangle(
          currentX / px * textureSource.width,
          currentY / py * textureSource.height,
          paddedWidth / px * textureSource.width,
          paddedHeight / py * textureSource.height
        );
        this.chars[char].texture = new Texture({
          source: textureSource,
          frame
        });
        currentX += Math.ceil(paddedWidth);
      }
    }
    textureSource.update();
    this._currentX = currentX;
    this._currentY = currentY;
    this._currentMaxCharHeight = currentMaxCharHeight;
    if (!this._skipKerning) this._applyKerning(charList, context, fontScale);
  }
  /**
   * @deprecated since 8.0.0
   * The map of base page textures (i.e., sheets of glyphs).
   */
  get pageTextures() {
    deprecation(v8_0_0, "BitmapFont.pageTextures is deprecated, please use BitmapFont.pages instead.");
    return this.pages;
  }
  _applyKerning(newChars, context, fontScale) {
    const measureCache = this._measureCache;
    for (let i = 0; i < newChars.length; i++) {
      const first = newChars[i];
      for (let j = 0; j < this._currentChars.length; j++) {
        const second = this._currentChars[j];
        let c1 = measureCache[first];
        if (!c1) c1 = measureCache[first] = context.measureText(first).width;
        let c2 = measureCache[second];
        if (!c2) c2 = measureCache[second] = context.measureText(second).width;
        let total = context.measureText(first + second).width;
        let amount = total - (c1 + c2);
        if (amount && this.chars[first]) {
          this.chars[first].kerning[second] = amount / fontScale;
        }
        total = context.measureText(first + second).width;
        amount = total - (c1 + c2);
        if (amount && this.chars[second]) {
          this.chars[second].kerning[first] = amount / fontScale;
        }
      }
    }
  }
  _nextPage() {
    this._currentPageIndex++;
    const textureResolution = this.resolution;
    const canvasAndContext = CanvasPool.getOptimalCanvasAndContext(
      this._textureSize,
      this._textureSize,
      textureResolution
    );
    this._setupContext(canvasAndContext.context, this._style, textureResolution);
    const resolution = textureResolution * (this.baseRenderedFontSize / this.baseMeasurementFontSize);
    const texture = new Texture({
      source: new ImageSource({
        resource: canvasAndContext.canvas,
        resolution,
        alphaMode: "premultiply-alpha-on-upload",
        autoGenerateMipmaps: this._mipmap
      })
    });
    if (this._textureStyle) {
      texture.source.style = this._textureStyle;
    }
    const pageData = {
      canvasAndContext,
      texture
    };
    this.pages[this._currentPageIndex] = pageData;
    return pageData;
  }
  // canvas style!
  _setupContext(context, style, resolution) {
    style.fontSize = this.baseRenderedFontSize;
    context.scale(resolution, resolution);
    context.font = fontStringFromTextStyle(style);
    style.fontSize = this.baseMeasurementFontSize;
    context.textBaseline = style.textBaseline;
    const stroke = style._stroke;
    const strokeThickness = stroke?.width ?? 0;
    if (stroke) {
      context.lineWidth = strokeThickness;
      context.lineJoin = stroke.join;
      context.miterLimit = stroke.miterLimit;
      context.strokeStyle = getCanvasFillStyle(stroke, context);
    }
    if (style._fill) {
      context.fillStyle = getCanvasFillStyle(style._fill, context);
    }
    if (style.dropShadow) {
      const shadowOptions = style.dropShadow;
      const rgb = Color.shared.setValue(shadowOptions.color).toArray();
      const dropShadowBlur = shadowOptions.blur * resolution;
      const dropShadowDistance = shadowOptions.distance * resolution;
      context.shadowColor = `rgba(${rgb[0] * 255},${rgb[1] * 255},${rgb[2] * 255},${shadowOptions.alpha})`;
      context.shadowBlur = dropShadowBlur;
      context.shadowOffsetX = Math.cos(shadowOptions.angle) * dropShadowDistance;
      context.shadowOffsetY = Math.sin(shadowOptions.angle) * dropShadowDistance;
    } else {
      context.shadowColor = "black";
      context.shadowBlur = 0;
      context.shadowOffsetX = 0;
      context.shadowOffsetY = 0;
    }
  }
  _drawGlyph(context, metrics, x, y, fontScale, style) {
    const char = metrics.text;
    const fontProperties = metrics.fontProperties;
    const stroke = style._stroke;
    const strokeThickness = (stroke?.width ?? 0) * fontScale;
    const tx = x + strokeThickness / 2;
    const ty = y - strokeThickness / 2;
    const descent = fontProperties.descent * fontScale;
    const lineHeight = metrics.lineHeight * fontScale;
    let removeShadow = false;
    if (style.stroke && strokeThickness) {
      removeShadow = true;
      context.strokeText(char, tx, ty + lineHeight - descent);
    }
    const { shadowBlur, shadowOffsetX, shadowOffsetY } = context;
    if (style._fill) {
      if (removeShadow) {
        context.shadowBlur = 0;
        context.shadowOffsetX = 0;
        context.shadowOffsetY = 0;
      }
      context.fillText(char, tx, ty + lineHeight - descent);
    }
    if (removeShadow) {
      context.shadowBlur = shadowBlur;
      context.shadowOffsetX = shadowOffsetX;
      context.shadowOffsetY = shadowOffsetY;
    }
  }
  destroy() {
    super.destroy();
    for (let i = 0; i < this.pages.length; i++) {
      const { canvasAndContext, texture } = this.pages[i];
      CanvasPool.returnCanvasAndContext(canvasAndContext);
      texture.destroy(true);
    }
    this.pages = null;
  }
};
_DynamicBitmapFont.defaultOptions = {
  textureSize: 512,
  style: new TextStyle(),
  mipmap: true
};
let DynamicBitmapFont = _DynamicBitmapFont;

export { DynamicBitmapFont };
//# sourceMappingURL=DynamicBitmapFont.mjs.map
