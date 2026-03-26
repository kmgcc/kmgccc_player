'use strict';

var Container = require('../container/Container.js');
var TextStyle = require('../text/TextStyle.js');

"use strict";
class AbstractSplitText extends Container.Container {
  constructor(config) {
    const {
      text,
      style,
      autoSplit,
      lineAnchor,
      wordAnchor,
      charAnchor,
      ...options
    } = config;
    super(options);
    this._dirty = false;
    this._canReuseChars = false;
    this.chars = [];
    this.words = [];
    this.lines = [];
    this._originalText = text;
    this._autoSplit = autoSplit;
    this._lineAnchor = lineAnchor;
    this._wordAnchor = wordAnchor;
    this._charAnchor = charAnchor;
    this.style = style;
  }
  /**
   * Splits the text into lines, words, and characters.
   * Call this manually when autoSplit is false.
   * @example Manual Splitting
   * ```ts
   * const text = new SplitText({
   *   text: 'Manual Update',
   *   autoSplit: false
   * });
   *
   * text.text = 'New Content';
   * text.style = { fontSize: 32 };
   * text.split(); // Apply changes
   * ```
   */
  split() {
    const res = this.splitFn();
    this.chars = res.chars;
    this.words = res.words;
    this.lines = res.lines;
    this.addChild(...this.lines);
    this.charAnchor = this._charAnchor;
    this.wordAnchor = this._wordAnchor;
    this.lineAnchor = this._lineAnchor;
    this._dirty = false;
    this._canReuseChars = true;
  }
  get text() {
    return this._originalText;
  }
  /**
   * Gets or sets the text content.
   * Setting new text triggers splitting if autoSplit is true.
   * > [!NOTE] Setting this frequently can have a performance impact, especially with large texts and canvas text.
   * @example Dynamic Text Updates
   * ```ts
   * const text = new SplitText({
   *   text: 'Original',
   *   autoSplit: true
   * });
   *
   * // Auto-splits on change
   * text.text = 'Updated Content';
   *
   * // Manual update
   * text.autoSplit = false;
   * text.text = 'Manual Update';
   * text.split();
   * ```
   */
  set text(value) {
    this._originalText = value;
    this.lines.forEach((line) => line.destroy({ children: true }));
    this.lines.length = 0;
    this.words.length = 0;
    this.chars.length = 0;
    this._canReuseChars = false;
    this.onTextUpdate();
  }
  _setOrigin(value, elements, property) {
    let originPoint;
    if (typeof value === "number") {
      originPoint = { x: value, y: value };
    } else {
      originPoint = { x: value.x, y: value.y };
    }
    elements.forEach((element) => {
      const localBounds = element.getLocalBounds();
      const originX = localBounds.minX + localBounds.width * originPoint.x;
      const originY = localBounds.minY + localBounds.height * originPoint.y;
      element.origin.set(originX, originY);
    });
    this[property] = value;
  }
  /**
   * Gets or sets the transform anchor for line segments.
   * The anchor point determines the center of rotation and scaling for each line.
   * @example Setting Line Anchors
   * ```ts
   * // Center rotation/scaling
   * text.lineAnchor = 0.5;
   *
   * // Rotate/scale from top-right corner
   * text.lineAnchor = { x: 1, y: 0 };
   *
   * // Custom anchor point
   * text.lineAnchor = {
   *   x: 0.2, // 20% from left
   *   y: 0.8  // 80% from top
   * };
   * ```
   */
  get lineAnchor() {
    return this._lineAnchor;
  }
  set lineAnchor(value) {
    this._setOrigin(value, this.lines, "_lineAnchor");
  }
  /**
   * Gets or sets the transform anchor for word segments.
   * The anchor point determines the center of rotation and scaling for each word.
   * @example
   * ```ts
   * // Center each word
   * text.wordAnchor = 0.5;
   *
   * // Scale from bottom-left
   * text.wordAnchor = { x: 0, y: 1 };
   *
   * // Rotate around custom point
   * text.wordAnchor = {
   *   x: 0.75,  // 75% from left
   *   y: 0.5    // Middle vertically
   * };
   * ```
   */
  get wordAnchor() {
    return this._wordAnchor;
  }
  set wordAnchor(value) {
    this._setOrigin(value, this.words, "_wordAnchor");
  }
  /**
   * Gets or sets the transform anchor for character segments.
   * The anchor point determines the center of rotation and scaling for each character.
   * @example Setting Character Anchors
   * ```ts
   * // Center each character
   * text.charAnchor = 0.5;
   *
   * // Rotate from top-center
   * text.charAnchor = { x: 0.5, y: 0 };
   *
   * // Scale from bottom-right
   * text.charAnchor = { x: 1, y: 1 };
   * ```
   * @example Animation with Anchors
   * ```ts
   * // Rotate characters around their centers
   * text.charAnchor = 0.5;
   * text.chars.forEach((char, i) => {
   *   gsap.to(char, {
   *     rotation: Math.PI * 2,
   *     duration: 1,
   *     delay: i * 0.1,
   *     repeat: -1
   *   });
   * });
   * ```
   */
  get charAnchor() {
    return this._charAnchor;
  }
  set charAnchor(value) {
    this._setOrigin(value, this.chars, "_charAnchor");
  }
  get style() {
    return this._style;
  }
  /**
   * The style configuration for the text.
   * Can be a TextStyle instance or a configuration object.
   * @example
   * ```ts
   * const text = new Text({
   *     text: 'Styled Text',
   *     style: {
   *         fontSize: 24,
   *         fill: 0xff1010, // Red color
   *         fontFamily: 'Arial',
   *         align: 'center', // Center alignment
   *         stroke: { color: '#4a1850', width: 5 }, // Purple stroke
   *         dropShadow: {
   *             color: '#000000', // Black shadow
   *             blur: 4, // Shadow blur
   *             distance: 6 // Shadow distance
   *         }
   *     }
   * });
   * // Update style dynamically
   * text.style = {
   *     fontSize: 30, // Change font size
   *     fill: 0x00ff00, // Change color to green
   *     align: 'right', // Change alignment to right
   *     stroke: { color: '#000000', width: 2 }, // Add black stroke
   * }
   */
  set style(style) {
    style || (style = {});
    this._style = new TextStyle.TextStyle(style);
    this.styleChanged();
  }
  /**
   * Used to notify the text that the style has changed.
   * This will re-split the text and re-apply the style.
   * @example
   * ```ts
   * text.style.fontSize = 32;
   * text.styleChanged();
   * ```
   */
  styleChanged() {
    this.words.forEach((word) => word.destroy());
    this.words.length = 0;
    this.lines.forEach((line) => line.destroy());
    this.lines.length = 0;
    this._canReuseChars = true;
    this.onTextUpdate();
  }
  onTextUpdate() {
    this._dirty = true;
    if (this._autoSplit) {
      this.split();
    }
  }
  /**
   * Destroys the SplitText instance and all its resources.
   * Cleans up all segment arrays, event listeners, and optionally the text style.
   * @param options - Destroy configuration options
   * @example
   * ```ts
   * // Clean up everything
   * text.destroy({ children: true, texture: true, style: true });
   *
   * // Remove from parent but keep style
   * text.destroy({ children: true, style: false });
   * ```
   */
  destroy(options) {
    super.destroy(options);
    this.chars = [];
    this.words = [];
    this.lines = [];
    if (typeof options === "boolean" ? options : options?.style) {
      this._style.destroy(options);
    }
    this._style = null;
    this._originalText = "";
  }
}

exports.AbstractSplitText = AbstractSplitText;
//# sourceMappingURL=AbstractSplitText.js.map
