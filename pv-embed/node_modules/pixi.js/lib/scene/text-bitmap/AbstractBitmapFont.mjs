import EventEmitter from 'eventemitter3';
import { deprecation, v8_0_0 } from '../../utils/logging/deprecation.mjs';

"use strict";
class AbstractBitmapFont extends EventEmitter {
  constructor() {
    super(...arguments);
    /** The map of characters by character string. */
    this.chars = /* @__PURE__ */ Object.create(null);
    /**
     * The line-height of the font face in pixels.
     * @type {number}
     */
    this.lineHeight = 0;
    /**
     * The name of the font face
     * @type {string}
     */
    this.fontFamily = "";
    /** The metrics of the font face. */
    this.fontMetrics = { fontSize: 0, ascent: 0, descent: 0 };
    /**
     * The offset of the font face from the baseline.
     * @type {number}
     */
    this.baseLineOffset = 0;
    /** The range and type of the distance field for this font. */
    this.distanceField = { type: "none", range: 0 };
    /** The map of base page textures (i.e., sheets of glyphs). */
    this.pages = [];
    /** should the fill for this font be applied as a tint to the text. */
    this.applyFillAsTint = true;
    /** The size of the font face in pixels. */
    this.baseMeasurementFontSize = 100;
    this.baseRenderedFontSize = 100;
  }
  /**
   * The name of the font face.
   * @deprecated since 8.0.0 Use `fontFamily` instead.
   */
  get font() {
    deprecation(v8_0_0, "BitmapFont.font is deprecated, please use BitmapFont.fontFamily instead.");
    return this.fontFamily;
  }
  /**
   * The map of base page textures (i.e., sheets of glyphs).
   * @deprecated since 8.0.0 Use `pages` instead.
   */
  get pageTextures() {
    deprecation(v8_0_0, "BitmapFont.pageTextures is deprecated, please use BitmapFont.pages instead.");
    return this.pages;
  }
  /**
   * The size of the font face in pixels.
   * @deprecated since 8.0.0 Use `fontMetrics.fontSize` instead.
   */
  get size() {
    deprecation(v8_0_0, "BitmapFont.size is deprecated, please use BitmapFont.fontMetrics.fontSize instead.");
    return this.fontMetrics.fontSize;
  }
  /**
   * The kind of distance field for this font or "none".
   * @deprecated since 8.0.0 Use `distanceField.type` instead.
   */
  get distanceFieldRange() {
    deprecation(v8_0_0, "BitmapFont.distanceFieldRange is deprecated, please use BitmapFont.distanceField.range instead.");
    return this.distanceField.range;
  }
  /**
   * The range of the distance field in pixels.
   * @deprecated since 8.0.0 Use `distanceField.range` instead.
   */
  get distanceFieldType() {
    deprecation(v8_0_0, "BitmapFont.distanceFieldType is deprecated, please use BitmapFont.distanceField.type instead.");
    return this.distanceField.type;
  }
  destroy(destroyTextures = false) {
    this.emit("destroy", this);
    this.removeAllListeners();
    for (const i in this.chars) {
      this.chars[i].texture?.destroy();
    }
    this.chars = null;
    if (destroyTextures) {
      this.pages.forEach((page) => page.texture.destroy(true));
      this.pages = null;
    }
  }
}

export { AbstractBitmapFont };
//# sourceMappingURL=AbstractBitmapFont.mjs.map
