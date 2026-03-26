import { ObservablePoint } from '../../maths/point/ObservablePoint.mjs';
import { deprecation, v8_0_0 } from '../../utils/logging/deprecation.mjs';
import { ViewContainer } from '../view/ViewContainer.mjs';

"use strict";
class AbstractText extends ViewContainer {
  constructor(options, styleClass) {
    const { text, resolution, style, anchor, width, height, roundPixels, ...rest } = options;
    super({
      ...rest
    });
    /** @internal */
    this.batched = true;
    /** @internal */
    this._resolution = null;
    /** @internal */
    this._autoResolution = true;
    /** @internal */
    this._didTextUpdate = true;
    this._styleClass = styleClass;
    this.text = text ?? "";
    this.style = style;
    this.resolution = resolution ?? null;
    this.allowChildren = false;
    this._anchor = new ObservablePoint(
      {
        _onUpdate: () => {
          this.onViewUpdate();
        }
      }
    );
    if (anchor) this.anchor = anchor;
    this.roundPixels = roundPixels ?? false;
    if (width !== void 0) this.width = width;
    if (height !== void 0) this.height = height;
  }
  /**
   * The anchor point of the text that controls the origin point for positioning and rotation.
   * Can be a number (same value for x/y) or a PointData object.
   * - (0,0) is top-left
   * - (0.5,0.5) is center
   * - (1,1) is bottom-right
   * ```ts
   * // Set anchor to center
   * const text = new Text({
   *     text: 'Hello Pixi!',
   *     anchor: 0.5 // Same as { x: 0.5, y: 0.5 }
   * });
   * // Set anchor to top-left
   * const text2 = new Text({
   *     text: 'Hello Pixi!',
   *     anchor: { x: 0, y: 0 } // Top-left corner
   * });
   * // Set anchor to bottom-right
   * const text3 = new Text({
   *     text: 'Hello Pixi!',
   *     anchor: { x: 1, y: 1 } // Bottom-right corner
   * });
   * ```
   * @default { x: 0, y: 0 }
   */
  get anchor() {
    return this._anchor;
  }
  set anchor(value) {
    typeof value === "number" ? this._anchor.set(value) : this._anchor.copyFrom(value);
  }
  /**
   * The text content to display. Use '\n' for line breaks.
   * Accepts strings, numbers, or objects with toString() method.
   * @example
   * ```ts
   * const text = new Text({
   *     text: 'Hello Pixi!',
   * });
   * const multilineText = new Text({
   *     text: 'Line 1\nLine 2\nLine 3',
   * });
   * const numberText = new Text({
   *     text: 12345, // Will be converted to '12345'
   * });
   * const objectText = new Text({
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
  set text(value) {
    value = value.toString();
    if (this._text === value) return;
    this._text = value;
    this.onViewUpdate();
  }
  get text() {
    return this._text;
  }
  /**
   * The resolution/device pixel ratio for rendering.
   * Higher values result in sharper text at the cost of performance.
   * Set to null for auto-resolution based on device.
   * @example
   * ```ts
   * const text = new Text({
   *     text: 'Hello Pixi!',
   *     resolution: 2 // High DPI for sharper text
   * });
   * const autoResText = new Text({
   *     text: 'Auto Resolution',
   *     resolution: null // Use device's pixel ratio
   * });
   * ```
   * @default null
   */
  set resolution(value) {
    this._autoResolution = value === null;
    this._resolution = value;
    this.onViewUpdate();
  }
  get resolution() {
    return this._resolution;
  }
  get style() {
    return this._style;
  }
  /**
   * The style configuration for the text.
   * Can be a TextStyle instance or a configuration object.
   * Supports canvas text styles, HTML text styles, and bitmap text styles.
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
   * const htmlText = new HTMLText({
   *     text: 'HTML Styled Text',
   *     style: {
   *         fontSize: '20px',
   *         fill: 'blue',
   *         fontFamily: 'Verdana',
   *     }
   * });
   * const bitmapText = new BitmapText({
   *     text: 'Bitmap Styled Text',
   *     style: {
   *         fontName: 'Arial',
   *         fontSize: 32,
   *     }
   * })
   *
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
    this._style?.off("update", this.onViewUpdate, this);
    if (style instanceof this._styleClass) {
      this._style = style;
    } else {
      this._style = new this._styleClass(style);
    }
    this._style.on("update", this.onViewUpdate, this);
    this.onViewUpdate();
  }
  /**
   * The width of the sprite, setting this will actually modify the scale to achieve the value set.
   * @example
   * ```ts
   * // Set width directly
   * texture.width = 200;
   * console.log(texture.scale.x); // Scale adjusted to match width
   *
   * // For better performance when setting both width and height
   * texture.setSize(300, 400); // Avoids recalculating bounds twice
   * ```
   */
  get width() {
    return Math.abs(this.scale.x) * this.bounds.width;
  }
  set width(value) {
    this._setWidth(value, this.bounds.width);
  }
  /**
   * The height of the sprite, setting this will actually modify the scale to achieve the value set.
   * @example
   * ```ts
   * // Set height directly
   * texture.height = 200;
   * console.log(texture.scale.y); // Scale adjusted to match height
   *
   * // For better performance when setting both width and height
   * texture.setSize(300, 400); // Avoids recalculating bounds twice
   * ```
   */
  get height() {
    return Math.abs(this.scale.y) * this.bounds.height;
  }
  set height(value) {
    this._setHeight(value, this.bounds.height);
  }
  /**
   * Retrieves the size of the Text as a [Size]{@link Size} object based on the texture dimensions and scale.
   * This is faster than getting width and height separately as it only calculates the bounds once.
   * @example
   * ```ts
   * // Basic size retrieval
   * const text = new Text({
   *     text: 'Hello Pixi!',
   *     style: { fontSize: 24 }
   * });
   * const size = text.getSize();
   * console.log(`Size: ${size.width}x${size.height}`);
   *
   * // Reuse existing size object
   * const reuseSize = { width: 0, height: 0 };
   * text.getSize(reuseSize);
   * ```
   * @param out - Optional object to store the size in, to avoid allocating a new object
   * @returns The size of the Sprite
   * @see {@link Text#width} For getting just the width
   * @see {@link Text#height} For getting just the height
   * @see {@link Text#setSize} For setting both width and height
   */
  getSize(out) {
    out || (out = {});
    out.width = Math.abs(this.scale.x) * this.bounds.width;
    out.height = Math.abs(this.scale.y) * this.bounds.height;
    return out;
  }
  /**
   * Sets the size of the Text to the specified width and height.
   * This is faster than setting width and height separately as it only recalculates bounds once.
   * @example
   * ```ts
   * // Basic size setting
   * const text = new Text({
   *    text: 'Hello Pixi!',
   *    style: { fontSize: 24 }
   * });
   * text.setSize(100, 200); // Width: 100, Height: 200
   *
   * // Set uniform size
   * text.setSize(100); // Sets both width and height to 100
   *
   * // Set size with object
   * text.setSize({
   *     width: 200,
   *     height: 300
   * });
   * ```
   * @param value - This can be either a number or a {@link Size} object
   * @param height - The height to set. Defaults to the value of `width` if not provided
   * @see {@link Text#width} For setting width only
   * @see {@link Text#height} For setting height only
   */
  setSize(value, height) {
    if (typeof value === "object") {
      height = value.height ?? value.width;
      value = value.width;
    } else {
      height ?? (height = value);
    }
    value !== void 0 && this._setWidth(value, this.bounds.width);
    height !== void 0 && this._setHeight(height, this.bounds.height);
  }
  /**
   * Checks if the object contains the given point in local coordinates.
   * Uses the text's bounds for hit testing.
   * @example
   * ```ts
   * // Basic point check
   * const localPoint = { x: 50, y: 25 };
   * const contains = text.containsPoint(localPoint);
   * console.log('Point is inside:', contains);
   * ```
   * @param point - The point to check in local coordinates
   * @returns True if the point is within the text's bounds
   * @see {@link Container#toLocal} For converting global coordinates to local
   */
  containsPoint(point) {
    const width = this.bounds.width;
    const height = this.bounds.height;
    const x1 = -width * this.anchor.x;
    let y1 = 0;
    if (point.x >= x1 && point.x <= x1 + width) {
      y1 = -height * this.anchor.y;
      if (point.y >= y1 && point.y <= y1 + height) return true;
    }
    return false;
  }
  /** @internal */
  onViewUpdate() {
    if (!this.didViewUpdate) this._didTextUpdate = true;
    super.onViewUpdate();
  }
  /**
   * Destroys this text renderable and optionally its style texture.
   * @param options - Options parameter. A boolean will act as if all options
   *  have been set to that value
   * @example
   * // Destroys the text and its style
   * text.destroy({ style: true, texture: true, textureSource: true });
   * text.destroy(true);
   * text.destroy() // Destroys the text, but not its style
   */
  destroy(options = false) {
    super.destroy(options);
    this.owner = null;
    this._bounds = null;
    this._anchor = null;
    if (typeof options === "boolean" ? options : options?.style) {
      this._style.destroy(options);
    }
    this._style = null;
    this._text = null;
  }
  /**
   * Returns a unique key for this instance.
   * This key is used for caching.
   * @returns {string} Unique key for the instance
   */
  get styleKey() {
    return `${this._text}:${this._style.styleKey}:${this._resolution}`;
  }
}
function ensureTextOptions(args, name) {
  let options = args[0] ?? {};
  if (typeof options === "string" || args[1]) {
    deprecation(v8_0_0, `use new ${name}({ text: "hi!", style }) instead`);
    options = {
      text: options,
      style: args[1]
    };
  }
  return options;
}

export { AbstractText, ensureTextOptions };
//# sourceMappingURL=AbstractText.mjs.map
