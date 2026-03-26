import { TextureSource } from '../../rendering/renderers/shared/texture/sources/TextureSource.mjs';
import { TextureStyle } from '../../rendering/renderers/shared/texture/TextureStyle.mjs';
import { AbstractText, ensureTextOptions } from '../text/AbstractText.mjs';
import { HTMLTextStyle } from './HTMLTextStyle.mjs';
import { measureHtmlText } from './utils/measureHtmlText.mjs';
import './init.mjs';

"use strict";
class HTMLText extends AbstractText {
  constructor(...args) {
    const options = ensureTextOptions(args, "HtmlText");
    super(options, HTMLTextStyle);
    /** @internal */
    this.renderPipeId = "htmlText";
    if (options.textureStyle) {
      this.textureStyle = options.textureStyle instanceof TextureStyle ? options.textureStyle : new TextureStyle(options.textureStyle);
    }
    this.autoGenerateMipmaps = options.autoGenerateMipmaps ?? TextureSource.defaultOptions.autoGenerateMipmaps;
  }
  /** @private */
  updateBounds() {
    const bounds = this._bounds;
    const anchor = this._anchor;
    const htmlMeasurement = measureHtmlText(this.text, this._style);
    const { width, height } = htmlMeasurement;
    bounds.minX = -anchor._x * width;
    bounds.maxX = bounds.minX + width;
    bounds.minY = -anchor._y * height;
    bounds.maxY = bounds.minY + height;
  }
  get text() {
    return this._text;
  }
  /**
   * The text content to display. Use '\n' for line breaks.
   * Accepts strings, numbers, or objects with toString() method.
   * @example
   * ```ts
   * const text = new HTMLText({
   *     text: 'Hello Pixi!',
   * });
   * const multilineText = new HTMLText({
   *     text: 'Line 1\nLine 2\nLine 3',
   * });
   * const numberText = new HTMLText({
   *     text: 12345, // Will be converted to '12345'
   * });
   * const objectText = new HTMLText({
   *     text: { toString: () => 'Object Text' }, // Custom toString
   * });
   *
   * // Update text dynamically
   * text.text = 'Updated Text'; // Re-renders with new text
   * text.text = 67890; // Updates to '67890'
   * text.text = { toString: () => 'Dynamic Text' }; // Uses custom toString method
   * // Clear text
   * text.text = ''; // Clears the text
   * ```
   * @default ''
   */
  set text(text) {
    const sanitisedText = this._sanitiseText(text.toString());
    super.text = sanitisedText;
  }
  /**
   * Sanitise text - replace `<br>` with `<br/>`, `&nbsp;` with `&#160;`
   * @param text
   * @see https://www.sitepoint.com/community/t/xhtml-1-0-transitional-xml-parsing-error-entity-nbsp-not-defined/3392/3
   */
  _sanitiseText(text) {
    return this._removeInvalidHtmlTags(text.replace(/<br>/gi, "<br/>").replace(/<hr>/gi, "<hr/>").replace(/&nbsp;/gi, "&#160;"));
  }
  _removeInvalidHtmlTags(input) {
    const brokenTagPattern = /<[^>]*?(?=<|$)/g;
    return input.replace(brokenTagPattern, "");
  }
}

export { HTMLText };
//# sourceMappingURL=HTMLText.mjs.map
