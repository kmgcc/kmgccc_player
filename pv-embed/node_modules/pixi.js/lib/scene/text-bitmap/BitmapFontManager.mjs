import { lru } from 'tiny-lru';
import { Cache } from '../../assets/cache/Cache.mjs';
import { deprecation, v8_0_0 } from '../../utils/logging/deprecation.mjs';
import { warn } from '../../utils/logging/warn.mjs';
import { CanvasTextMetrics } from '../text/canvas/CanvasTextMetrics.mjs';
import { TextStyle } from '../text/TextStyle.mjs';
import { DynamicBitmapFont } from './DynamicBitmapFont.mjs';
import { getBitmapTextLayout } from './utils/getBitmapTextLayout.mjs';
import { resolveCharacters } from './utils/resolveCharacters.mjs';

"use strict";
let fontCount = 0;
class BitmapFontManagerClass {
  constructor() {
    /**
     * This character set includes all the letters in the alphabet (both lower- and upper- case).
     * @type {string[][]}
     * @example
     * BitmapFont.from('ExampleFont', style, { chars: BitmapFont.ALPHA })
     */
    this.ALPHA = [["a", "z"], ["A", "Z"], " "];
    /**
     * This character set includes all decimal digits (from 0 to 9).
     * @type {string[][]}
     * @example
     * BitmapFont.from('ExampleFont', style, { chars: BitmapFont.NUMERIC })
     */
    this.NUMERIC = [["0", "9"]];
    /**
     * This character set is the union of `BitmapFont.ALPHA` and `BitmapFont.NUMERIC`.
     * @type {string[][]}
     */
    this.ALPHANUMERIC = [["a", "z"], ["A", "Z"], ["0", "9"], " "];
    /**
     * This character set consists of all the ASCII table.
     * @type {string[][]}
     * @see http://www.asciitable.com/
     */
    this.ASCII = [[" ", "~"]];
    /** Default options for installing a new BitmapFont. */
    this.defaultOptions = {
      chars: this.ALPHANUMERIC,
      resolution: 1,
      padding: 4,
      skipKerning: false,
      textureStyle: null
    };
    /** Cache for measured text layouts to avoid recalculating them multiple times. */
    this.measureCache = lru(1e3);
  }
  /**
   * Get a font for the specified text and style.
   * @param text - The text to get the font for
   * @param style - The style to use
   */
  getFont(text, style) {
    let fontFamilyKey = `${style.fontFamily}-bitmap`;
    let overrideFill = true;
    if (Cache.has(fontFamilyKey)) {
      const dynamicFont2 = Cache.get(fontFamilyKey);
      dynamicFont2.ensureCharacters?.(text);
      return dynamicFont2;
    }
    if (style._fill.fill && !style._stroke) {
      fontFamilyKey += style._fill.fill.styleKey;
      overrideFill = false;
    } else if (style._stroke || style.dropShadow) {
      fontFamilyKey = `${style.styleKey}-bitmap`;
      overrideFill = false;
    }
    fontFamilyKey += `-${style.fontStyle}`;
    fontFamilyKey += `-${style.fontVariant}`;
    fontFamilyKey += `-${style.fontWeight}`;
    if (!Cache.has(fontFamilyKey)) {
      const styleCopy = Object.create(style);
      styleCopy["_lineHeight"] = 0;
      const fnt = new DynamicBitmapFont({
        style: styleCopy,
        overrideFill,
        overrideSize: true,
        ...this.defaultOptions
      });
      fontCount++;
      if (fontCount > 50) {
        warn("BitmapText", `You have dynamically created ${fontCount} bitmap fonts, this can be inefficient. Try pre installing your font styles using \`BitmapFont.install({name:"style1", style})\``);
      }
      fnt.once("destroy", () => {
        fontCount--;
        Cache.remove(fontFamilyKey);
      });
      Cache.set(
        fontFamilyKey,
        fnt
      );
    }
    const dynamicFont = Cache.get(fontFamilyKey);
    dynamicFont.ensureCharacters?.(text);
    return dynamicFont;
  }
  /**
   * Get the layout of a text for the specified style.
   * @param text - The text to get the layout for
   * @param style - The style to use
   * @param trimEnd - Whether to ignore whitespaces at the end of each line
   */
  getLayout(text, style, trimEnd = true) {
    const bitmapFont = this.getFont(text, style);
    const id = `${text}-${style.styleKey}-${trimEnd}`;
    if (this.measureCache.has(id)) {
      return this.measureCache.get(id);
    }
    const segments = CanvasTextMetrics.graphemeSegmenter(text);
    const layoutData = getBitmapTextLayout(segments, style, bitmapFont, trimEnd);
    this.measureCache.set(id, layoutData);
    return layoutData;
  }
  /**
   * Measure the text using the specified style.
   * @param text - The text to measure
   * @param style - The style to use
   * @param trimEnd - Whether to ignore whitespaces at the end of each line
   */
  measureText(text, style, trimEnd = true) {
    return this.getLayout(text, style, trimEnd);
  }
  // eslint-disable-next-line max-len
  install(...args) {
    let options = args[0];
    if (typeof options === "string") {
      options = {
        name: options,
        style: args[1],
        chars: args[2]?.chars,
        resolution: args[2]?.resolution,
        padding: args[2]?.padding,
        skipKerning: args[2]?.skipKerning
      };
      deprecation(v8_0_0, "BitmapFontManager.install(name, style, options) is deprecated, use BitmapFontManager.install({name, style, ...options})");
    }
    const name = options?.name;
    if (!name) {
      throw new Error("[BitmapFontManager] Property `name` is required.");
    }
    options = { ...this.defaultOptions, ...options };
    const textStyle = options.style;
    const style = textStyle instanceof TextStyle ? textStyle : new TextStyle(textStyle);
    const overrideFill = options.dynamicFill ?? this._canUseTintForStyle(style);
    const font = new DynamicBitmapFont({
      style,
      overrideFill,
      skipKerning: options.skipKerning,
      padding: options.padding,
      resolution: options.resolution,
      overrideSize: false,
      textureStyle: options.textureStyle
    });
    const flatChars = resolveCharacters(options.chars);
    font.ensureCharacters(flatChars.join(""));
    Cache.set(`${name}-bitmap`, font);
    font.once("destroy", () => Cache.remove(`${name}-bitmap`));
    return font;
  }
  /**
   * Uninstalls a bitmap font from the cache.
   * @param {string} name - The name of the bitmap font to uninstall.
   */
  uninstall(name) {
    const cacheKey = `${name}-bitmap`;
    const font = Cache.get(cacheKey);
    if (font) {
      font.destroy();
    }
  }
  /**
   * Determines if a style can use tinting instead of baking colors into the bitmap.
   * Tinting is more efficient as it allows reusing the same bitmap with different colors.
   * @param style - The text style to evaluate
   * @returns true if the style can use tinting, false if colors must be baked in
   * @private
   */
  _canUseTintForStyle(style) {
    return !style._stroke && (!style.dropShadow || style.dropShadow.color === 0) && !style._fill.fill && style._fill.color === 16777215;
  }
}
const BitmapFontManager = new BitmapFontManagerClass();

export { BitmapFontManager };
//# sourceMappingURL=BitmapFontManager.mjs.map
