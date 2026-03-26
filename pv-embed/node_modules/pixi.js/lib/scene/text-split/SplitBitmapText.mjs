import { warn } from '../../utils/logging/warn.mjs';
import { TextStyle } from '../text/TextStyle.mjs';
import { bitmapTextSplit } from '../text-bitmap/utils/bitmapTextSplit.mjs';
import { AbstractSplitText } from './AbstractSplitText.mjs';

"use strict";
const _SplitBitmapText = class _SplitBitmapText extends AbstractSplitText {
  constructor(config) {
    var _a;
    const completeOptions = {
      ..._SplitBitmapText.defaultOptions,
      ...config
    };
    completeOptions.style ?? (completeOptions.style = {});
    (_a = completeOptions.style).fill ?? (_a.fill = 16777215);
    super(completeOptions);
  }
  /**
   * Creates a SplitBitmapText instance from an existing text object.
   * Useful for converting standard Text or BitmapText objects into segmented versions.
   * @param text - The source text object to convert
   * @param options - Additional splitting options
   * @returns A new SplitBitmapText instance
   * @example
   * ```ts
   * const bitmapText = new BitmapText({
   *   text: 'Bitmap Text',
   *   style: { fontFamily: 'Arial' }
   * });
   *
   * const segmented = SplitBitmapText.from(bitmapText);
   *
   * // with additional options
   * const segmentedWithOptions = SplitBitmapText.from(bitmapText, {
   *   autoSplit: false,
   *   lineAnchor: 0.5,
   *   wordAnchor: { x: 0, y: 0.5 },
   * })
   * ```
   */
  static from(text, options) {
    const completeOptions = {
      ..._SplitBitmapText.defaultOptions,
      ...options,
      text: text.text,
      style: new TextStyle(text.style)
    };
    if (text.style.tagStyles) {
      warn("[SplitBitmapText] Tag styles are not supported for SplitBitmapText. They will be ignored.");
      text.style._tagStyles = void 0;
    }
    const splitText = new _SplitBitmapText({
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
    return bitmapTextSplit({
      text: this._originalText,
      style: this._style,
      chars: this._canReuseChars ? this.chars : []
    });
  }
};
/**
 * Default configuration options for SplitBitmapText instances.
 * @example
 * ```ts
 * // Override defaults globally
 * SplitBitmapText.defaultOptions = {
 *   autoSplit: false,
 *   lineAnchor: 0.5,  // Center alignment
 *   wordAnchor: { x: 0, y: 0.5 },  // Left-center
 *   charAnchor: { x: 0.5, y: 1 }   // Bottom-center
 * };
 * ```
 */
_SplitBitmapText.defaultOptions = {
  autoSplit: true,
  // Auto-update on text/style changes
  lineAnchor: 0,
  // Top-left alignment
  wordAnchor: 0,
  // Top-left alignment
  charAnchor: 0
  // Top-left alignment
};
let SplitBitmapText = _SplitBitmapText;

export { SplitBitmapText };
//# sourceMappingURL=SplitBitmapText.mjs.map
