'use strict';

var TextStyle = require('../text/TextStyle.js');
var canvasTextSplit = require('../text/utils/canvasTextSplit.js');
var AbstractSplitText = require('./AbstractSplitText.js');

"use strict";
const _SplitText = class _SplitText extends AbstractSplitText.AbstractSplitText {
  constructor(config) {
    const completeOptions = {
      ..._SplitText.defaultOptions,
      ...config
    };
    super(completeOptions);
  }
  /**
   * Creates a SplitText instance from an existing text object.
   * Useful for converting standard Text or Text objects into segmented versions.
   * @param text - The source text object to convert
   * @param options - Additional splitting options
   * @returns A new SplitText instance
   * @example
   * ```ts
   * const text = new Text({
   *   text: 'Bitmap Text',
   *   style: { fontFamily: 'Arial' }
   * });
   *
   * const segmented = SplitText.from(text);
   *
   * // with additional options
   * const segmentedWithOptions = SplitText.from(text, {
   *   autoSplit: false,
   *   lineAnchor: 0.5,
   *   wordAnchor: { x: 0, y: 0.5 },
   * })
   * ```
   */
  static from(text, options) {
    const completeOptions = {
      ..._SplitText.defaultOptions,
      ...options,
      text: text.text,
      style: new TextStyle.TextStyle(text.style)
    };
    const splitText = new _SplitText({
      ...completeOptions
    });
    const anchor = text.anchor;
    if (anchor.x !== 0 || anchor.y !== 0) {
      splitText.pivot.set(
        splitText.width * anchor.x,
        splitText.height * anchor.y
      );
    }
    return splitText;
  }
  splitFn() {
    return canvasTextSplit.canvasTextSplit({
      text: this._originalText,
      style: this._style,
      chars: this._canReuseChars ? this.chars : []
    });
  }
};
/**
 * Default configuration options for SplitText instances.
 * @example
 * ```ts
 * // Override defaults globally
 * SplitText.defaultOptions = {
 *   autoSplit: false,
 *   lineAnchor: 0.5,  // Center alignment
 *   wordAnchor: { x: 0, y: 0.5 },  // Left-center
 *   charAnchor: { x: 0.5, y: 1 }   // Bottom-center
 * };
 * ```
 */
_SplitText.defaultOptions = {
  autoSplit: true,
  // Auto-update on text/style changes
  lineAnchor: 0,
  // Top-left alignment
  wordAnchor: 0,
  // Top-left alignment
  charAnchor: 0
  // Top-left alignment
};
let SplitText = _SplitText;

exports.SplitText = SplitText;
//# sourceMappingURL=SplitText.js.map
