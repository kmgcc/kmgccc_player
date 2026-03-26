import { warn } from '../../utils/logging/warn.mjs';
import { TextStyle } from '../text/TextStyle.mjs';
import { textStyleToCSS } from './utils/textStyleToCSS.mjs';

"use strict";
class HTMLTextStyle extends TextStyle {
  constructor(options = {}) {
    super(options);
    this._cssOverrides = [];
    this.cssOverrides = options.cssOverrides ?? [];
    this.tagStyles = options.tagStyles ?? {};
  }
  /**
   * Custom styles to apply to specific HTML tags.
   * Allows for consistent styling of custom elements without CSS overrides.
   * @example
   * ```ts
   * const text = new HTMLText({
   *     text: '<red>Red</red>, <blue>Blue</blue>, <green>Green</green>',
   *     style: {
   *         tagStyles: {
   *             red: { fill: 'red' },
   *             blue: { fill: 'blue' },
   *             green: { fill: 'green' },
   *         }
   *     }
   * });
   * ```
   * @standard
   */
  get tagStyles() {
    return this._tagStyles;
  }
  /** @standard */
  set tagStyles(value) {
    if (this._tagStyles === value) return;
    this._tagStyles = value ?? {};
    this.update();
  }
  /**
   * List of CSS style overrides to apply to the HTML text.
   * These styles are added after the built-in styles and can override any default styling.
   * @advanced
   */
  set cssOverrides(value) {
    this._cssOverrides = value instanceof Array ? value : [value];
    this.update();
  }
  /** @advanced */
  get cssOverrides() {
    return this._cssOverrides;
  }
  /**
   * Updates the text style and triggers a refresh of the CSS style cache.
   * This method is called automatically when style properties are changed.
   * @example
   * ```ts
   * // Update after multiple changes
   * const text = new HTMLText({
   *     text: 'Hello World',
   *     style
   * });
   *
   * style.fontSize = 32;
   * style.fill = '#00ff00';
   * style.fontFamily = 'Arial';
   * style.update(); // Apply all changes at once
   * ```
   * @advanced
   * @see {@link HTMLTextStyle#cssStyle} For accessing the generated CSS
   * @see {@link HTMLTextStyle#cssOverrides} For managing CSS overrides
   */
  update() {
    this._cssStyle = null;
    super.update();
  }
  /**
   * Creates a new HTMLTextStyle object with the same values as this one.
   * This creates a deep copy of all style properties, including dropShadow and tag styles.
   * @example
   * ```ts
   * // Create original style
   * const originalStyle = new HTMLTextStyle({
   *     fontSize: 24,
   *     fill: '#ff0000',
   *     tagStyles: {
   *         header: { fontSize: 32, fill: '#00ff00' }
   *     }
   * });
   *
   * // Clone the style
   * const clonedStyle = originalStyle.clone();
   *
   * // Modify cloned style independently
   * clonedStyle.fontSize = 36;
   * clonedStyle.fill = '#0000ff';
   *
   * // Original style remains unchanged
   * console.log(originalStyle.fontSize); // Still 24
   * console.log(originalStyle.fill); // Still '#ff0000'
   * ```
   *
   * Properties that are cloned:
   * - Basic text properties (fontSize, fontFamily, etc.)
   * - Fill and stroke styles
   * - Drop shadow configuration
   * - CSS overrides
   * - Tag styles (deep copied)
   * - Word wrap settings
   * - Alignment and spacing
   * @returns {HTMLTextStyle} A new HTMLTextStyle instance with the same properties
   * @see {@link HTMLTextStyle} For available style properties
   * @see {@link HTMLTextStyle#cssOverrides} For CSS override handling
   * @see {@link HTMLTextStyle#tagStyles} For tag style configuration
   * @standard
   */
  clone() {
    return new HTMLTextStyle({
      align: this.align,
      breakWords: this.breakWords,
      dropShadow: this.dropShadow ? { ...this.dropShadow } : null,
      fill: this._fill,
      fontFamily: this.fontFamily,
      fontSize: this.fontSize,
      fontStyle: this.fontStyle,
      fontVariant: this.fontVariant,
      fontWeight: this.fontWeight,
      letterSpacing: this.letterSpacing,
      lineHeight: this.lineHeight,
      padding: this.padding,
      stroke: this._stroke,
      whiteSpace: this.whiteSpace,
      wordWrap: this.wordWrap,
      wordWrapWidth: this.wordWrapWidth,
      cssOverrides: this.cssOverrides,
      tagStyles: { ...this.tagStyles }
    });
  }
  /**
   * The CSS style string that will be applied to the HTML text.
   * @advanced
   */
  get cssStyle() {
    if (!this._cssStyle) {
      this._cssStyle = textStyleToCSS(this);
    }
    return this._cssStyle;
  }
  /**
   * Add a style override, this can be any CSS property
   * it will override any built-in style. This is the
   * property and the value as a string (e.g., `color: red`).
   * This will override any other internal style.
   * @param {string} value - CSS style(s) to add.
   * @example
   * style.addOverride('background-color: red');
   * @advanced
   */
  addOverride(...value) {
    const toAdd = value.filter((v) => !this.cssOverrides.includes(v));
    if (toAdd.length > 0) {
      this.cssOverrides.push(...toAdd);
      this.update();
    }
  }
  /**
   * Remove any overrides that match the value.
   * @param {string} value - CSS style to remove.
   * @example
   * style.removeOverride('background-color: red');
   * @advanced
   */
  removeOverride(...value) {
    const toRemove = value.filter((v) => this.cssOverrides.includes(v));
    if (toRemove.length > 0) {
      this.cssOverrides = this.cssOverrides.filter((v) => !toRemove.includes(v));
      this.update();
    }
  }
  /**
   * Sets the fill style for the text. HTML text only supports color fills (string or number values).
   * Texture fills are not supported and will trigger a warning in debug mode.
   * @example
   * ```ts
   * // Using hex colors
   * const text = new HTMLText({
   *     text: 'Colored Text',
   *     style: {
   *         fill: 0xff0000 // Red color
   *     }
   * });
   *
   * // Using CSS color strings
   * text.style.fill = '#00ff00';     // Hex string (Green)
   * text.style.fill = 'blue';        // Named color
   * text.style.fill = 'rgb(255,0,0)' // RGB
   * text.style.fill = '#f0f';        // Short hex
   *
   * // Invalid usage (will trigger warning in debug)
   * text.style.fill = {
   *     type: 'pattern',
   *     texture: Texture.from('pattern.png')
   * }; // Not supported, falls back to default
   * ```
   * @param value - The fill color to use. Must be a string or number.
   * @throws {Warning} In debug mode when attempting to use unsupported fill types
   * @see {@link TextStyle#fill} For full fill options in canvas text
   * @standard
   */
  set fill(value) {
    if (typeof value !== "string" && typeof value !== "number") {
      warn("[HTMLTextStyle] only color fill is not supported by HTMLText");
    }
    super.fill = value;
  }
  /**
   * Sets the stroke style for the text. HTML text only supports color strokes (string or number values).
   * Texture strokes are not supported and will trigger a warning in debug mode.
   * @example
   * ```ts
   * // Using hex colors
   * const text = new HTMLText({
   *     text: 'Outlined Text',
   *     style: {
   *         stroke: 0xff0000 // Red outline
   *     }
   * });
   *
   * // Using CSS color strings
   * text.style.stroke = '#00ff00';     // Hex string (Green)
   * text.style.stroke = 'blue';        // Named color
   * text.style.stroke = 'rgb(255,0,0)' // RGB
   * text.style.stroke = '#f0f';        // Short hex
   *
   * // Using stroke width
   * text.style = {
   *     stroke: {
   *         color: '#ff0000',
   *         width: 2
   *     }
   * };
   *
   * // Remove stroke
   * text.style.stroke = null;
   *
   * // Invalid usage (will trigger warning in debug)
   * text.style.stroke = {
   *     type: 'pattern',
   *     texture: Texture.from('pattern.png')
   * }; // Not supported, falls back to default
   * ```
   * @param value - The stroke style to use. Must be a string, number, or stroke configuration object
   * @throws {Warning} In debug mode when attempting to use unsupported stroke types
   * @see {@link TextStyle#stroke} For full stroke options in canvas text
   * @standard
   */
  set stroke(value) {
    if (value && typeof value !== "string" && typeof value !== "number") {
      warn("[HTMLTextStyle] only color stroke is not supported by HTMLText");
    }
    super.stroke = value;
  }
}

export { HTMLTextStyle };
//# sourceMappingURL=HTMLTextStyle.mjs.map
