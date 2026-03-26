'use strict';

var EventEmitter = require('eventemitter3');
var Color = require('../../color/Color.js');
var uid = require('../../utils/data/uid.js');
var deprecation = require('../../utils/logging/deprecation.js');
var warn = require('../../utils/logging/warn.js');
var FillGradient = require('../graphics/shared/fill/FillGradient.js');
var FillPattern = require('../graphics/shared/fill/FillPattern.js');
var GraphicsContext = require('../graphics/shared/GraphicsContext.js');
var convertFillInputToFillStyle = require('../graphics/shared/utils/convertFillInputToFillStyle.js');
var fontStringFromTextStyle = require('./canvas/utils/fontStringFromTextStyle.js');

"use strict";
const _TextStyle = class _TextStyle extends EventEmitter {
  constructor(style = {}) {
    super();
    /**
     * Unique identifier for the TextStyle class.
     * This is used to track instances and ensure uniqueness.
     * @internal
     */
    this.uid = uid.uid("textStyle");
    /**
     * Internal tick counter used to track updates and changes.
     * This is incremented whenever the style is modified, allowing for efficient change detection.
     * @internal
     */
    this._tick = 0;
    this._cachedFontString = null;
    convertV7Tov8Style(style);
    const isTextStyle = style instanceof _TextStyle;
    const existingStyle = style;
    if (isTextStyle) {
      style = existingStyle._toObject();
    }
    const fullStyle = { ..._TextStyle.defaultTextStyle, ...style };
    for (const key in fullStyle) {
      const thisKey = key;
      this[thisKey] = fullStyle[key];
    }
    this._tagStyles = style.tagStyles ?? void 0;
    this.update();
    this._tick = 0;
  }
  /**
   * Alignment for multiline text, does not affect single line text.
   * @type {'left'|'center'|'right'|'justify'}
   */
  get align() {
    return this._align;
  }
  set align(value) {
    if (this._align === value) return;
    this._align = value;
    this.update();
  }
  /** Indicates if lines can be wrapped within words, it needs wordWrap to be set to true. */
  get breakWords() {
    return this._breakWords;
  }
  set breakWords(value) {
    if (this._breakWords === value) return;
    this._breakWords = value;
    this.update();
  }
  /** Set a drop shadow for the text. */
  get dropShadow() {
    return this._dropShadow;
  }
  set dropShadow(value) {
    if (this._dropShadow === value) return;
    if (value !== null && typeof value === "object") {
      this._dropShadow = this._createProxy({ ..._TextStyle.defaultDropShadow, ...value });
    } else {
      this._dropShadow = value ? this._createProxy({ ..._TextStyle.defaultDropShadow }) : null;
    }
    this.update();
  }
  /** The font family, can be a single font name, or a list of names where the first is the preferred font. */
  get fontFamily() {
    return this._fontFamily;
  }
  set fontFamily(value) {
    if (this._fontFamily === value) return;
    this._fontFamily = value;
    this.update();
  }
  /** The font size (as a number it converts to px, but as a string, equivalents are '26px','20pt','160%' or '1.6em') */
  get fontSize() {
    return this._fontSize;
  }
  set fontSize(value) {
    if (this._fontSize === value) return;
    if (typeof value === "string") {
      this._fontSize = parseInt(value, 10);
    } else {
      this._fontSize = value;
    }
    this.update();
  }
  /**
   * The font style.
   * @type {'normal'|'italic'|'oblique'}
   */
  get fontStyle() {
    return this._fontStyle;
  }
  set fontStyle(value) {
    if (this._fontStyle === value) return;
    this._fontStyle = value.toLowerCase();
    this.update();
  }
  /**
   * The font variant.
   * @type {'normal'|'small-caps'}
   */
  get fontVariant() {
    return this._fontVariant;
  }
  set fontVariant(value) {
    if (this._fontVariant === value) return;
    this._fontVariant = value;
    this.update();
  }
  /**
   * The font weight.
   * @type {'normal'|'bold'|'bolder'|'lighter'|'100'|'200'|'300'|'400'|'500'|'600'|'700'|'800'|'900'}
   */
  get fontWeight() {
    return this._fontWeight;
  }
  set fontWeight(value) {
    if (this._fontWeight === value) return;
    this._fontWeight = value;
    this.update();
  }
  /** The space between lines. */
  get leading() {
    return this._leading;
  }
  set leading(value) {
    if (this._leading === value) return;
    this._leading = value;
    this.update();
  }
  /** The amount of spacing between letters, default is 0. */
  get letterSpacing() {
    return this._letterSpacing;
  }
  set letterSpacing(value) {
    if (this._letterSpacing === value) return;
    this._letterSpacing = value;
    this.update();
  }
  /** The line height, a number that represents the vertical space that a letter uses. */
  get lineHeight() {
    return this._lineHeight;
  }
  set lineHeight(value) {
    if (this._lineHeight === value) return;
    this._lineHeight = value;
    this.update();
  }
  /**
   * Occasionally some fonts are cropped. Adding some padding will prevent this from happening
   * by adding padding to all sides of the text.
   * > [!NOTE] This will NOT affect the positioning or bounds of the text.
   */
  get padding() {
    return this._padding;
  }
  set padding(value) {
    if (this._padding === value) return;
    this._padding = value;
    this.update();
  }
  /**
   * An optional filter or array of filters to apply to the text, allowing for advanced visual effects.
   * These filters will be applied to the text as it is created, resulting in faster rendering for static text
   * compared to applying the filter directly to the text object (which would be applied at run time).
   * @default null
   */
  get filters() {
    return this._filters;
  }
  set filters(value) {
    if (this._filters === value) return;
    this._filters = Object.freeze(value);
    this.update();
  }
  /**
   * Trim transparent borders from the text texture.
   * > [!IMPORTANT] PERFORMANCE WARNING:
   * > This is a costly operation as it requires scanning pixel alpha values.
   * > Avoid using `trim: true` for dynamic text, as it could significantly impact performance.
   */
  get trim() {
    return this._trim;
  }
  set trim(value) {
    if (this._trim === value) return;
    this._trim = value;
    this.update();
  }
  /**
   * The baseline of the text that is rendered.
   * @type {'alphabetic'|'top'|'hanging'|'middle'|'ideographic'|'bottom'}
   */
  get textBaseline() {
    return this._textBaseline;
  }
  set textBaseline(value) {
    if (this._textBaseline === value) return;
    this._textBaseline = value;
    this.update();
  }
  /**
   * How newlines and spaces should be handled.
   * Default is 'pre' (preserve, preserve).
   *
   *  value       | New lines     |   Spaces
   *  ---         | ---           |   ---
   * 'normal'     | Collapse      |   Collapse
   * 'pre'        | Preserve      |   Preserve
   * 'pre-line'   | Preserve      |   Collapse
   * @type {'normal'|'pre'|'pre-line'}
   */
  get whiteSpace() {
    return this._whiteSpace;
  }
  set whiteSpace(value) {
    if (this._whiteSpace === value) return;
    this._whiteSpace = value;
    this.update();
  }
  /** Indicates if word wrap should be used. */
  get wordWrap() {
    return this._wordWrap;
  }
  set wordWrap(value) {
    if (this._wordWrap === value) return;
    this._wordWrap = value;
    this.update();
  }
  /** The width at which text will wrap, it needs wordWrap to be set to true. */
  get wordWrapWidth() {
    return this._wordWrapWidth;
  }
  set wordWrapWidth(value) {
    if (this._wordWrapWidth === value) return;
    this._wordWrapWidth = value;
    this.update();
  }
  /**
   * The fill style that will be used to color the text.
   * This can be:
   * - A color string like 'red', '#00FF00', or 'rgba(255,0,0,0.5)'
   * - A hex number like 0xff0000 for red
   * - A FillStyle object with properties like { color: 0xff0000, alpha: 0.5 }
   * - A FillGradient for gradient fills
   * - A FillPattern for pattern/texture fills
   *
   * When using a FillGradient, vertical gradients (angle of 90 degrees) are applied per line of text,
   * while gradients at any other angle are spread across the entire text body as a whole.
   * @example
   * // Vertical gradient applied per line
   * const verticalGradient = new FillGradient(0, 0, 0, 1)
   *     .addColorStop(0, 0xff0000)
   *     .addColorStop(1, 0x0000ff);
   *
   * const text = new Text({
   *     text: 'Line 1\nLine 2',
   *     style: { fill: verticalGradient }
   * });
   *
   * To manage the gradient in a global scope, set the textureSpace property of the FillGradient to 'global'.
   * @type {string|number|FillStyle|FillGradient|FillPattern}
   */
  get fill() {
    return this._originalFill;
  }
  set fill(value) {
    if (value === this._originalFill) return;
    this._originalFill = value;
    if (this._isFillStyle(value)) {
      this._originalFill = this._createProxy({ ...GraphicsContext.GraphicsContext.defaultFillStyle, ...value }, () => {
        this._fill = convertFillInputToFillStyle.toFillStyle(
          { ...this._originalFill },
          GraphicsContext.GraphicsContext.defaultFillStyle
        );
      });
    }
    this._fill = convertFillInputToFillStyle.toFillStyle(
      value === 0 ? "black" : value,
      GraphicsContext.GraphicsContext.defaultFillStyle
    );
    this.update();
  }
  /** A fillstyle that will be used on the text stroke, e.g., 'blue', '#FCFF00'. */
  get stroke() {
    return this._originalStroke;
  }
  set stroke(value) {
    if (value === this._originalStroke) return;
    this._originalStroke = value;
    if (this._isFillStyle(value)) {
      this._originalStroke = this._createProxy({ ...GraphicsContext.GraphicsContext.defaultStrokeStyle, ...value }, () => {
        this._stroke = convertFillInputToFillStyle.toStrokeStyle(
          { ...this._originalStroke },
          GraphicsContext.GraphicsContext.defaultStrokeStyle
        );
      });
    }
    this._stroke = convertFillInputToFillStyle.toStrokeStyle(value, GraphicsContext.GraphicsContext.defaultStrokeStyle);
    this.update();
  }
  /**
   * Custom styles to apply to specific tags within the text.
   * Allows for rich text formatting using simple tag markup like `<red>text</red>`.
   *
   * Tags are only parsed when this property has entries. If `tagStyles` is undefined,
   * `<` characters in text are treated as literal.
   * @example
   * ```ts
   * const text = new Text({
   *     text: '<red>Red</red>, <blue>Blue</blue>',
   *     style: {
   *         fill: 'white',
   *         tagStyles: {
   *             red: { fill: 'red' },
   *             blue: { fill: 'blue' }
   *         }
   *     }
   * });
   * ```
   */
  get tagStyles() {
    return this._tagStyles;
  }
  set tagStyles(value) {
    if (this._tagStyles === value) return;
    this._tagStyles = value ?? void 0;
    this.update();
  }
  update() {
    this._tick++;
    this._cachedFontString = null;
    this.emit("update", this);
  }
  /** Resets all properties to the default values */
  reset() {
    const defaultStyle = _TextStyle.defaultTextStyle;
    for (const key in defaultStyle) {
      this[key] = defaultStyle[key];
    }
  }
  /**
   * Assigns partial style options to this TextStyle instance.
   * Uses public setters to ensure proper value transformation.
   * @param values - Partial style options to assign
   * @returns This TextStyle instance for chaining
   */
  assign(values) {
    for (const key in values) {
      const thisKey = key;
      this[thisKey] = values[key];
    }
    return this;
  }
  /**
   * Returns a unique key for this instance.
   * This key is used for caching.
   * @returns {string} Unique key for the instance
   */
  get styleKey() {
    return `${this.uid}-${this._tick}`;
  }
  /**
   * Returns the CSS font string for this style, cached for performance.
   * @internal
   * @returns CSS font string
   */
  get _fontString() {
    if (this._cachedFontString === null) {
      this._cachedFontString = fontStringFromTextStyle.fontStringFromTextStyle(this);
    }
    return this._cachedFontString;
  }
  /**
   * Returns an object with the same values as this TextStyle instance.
   * @returns Object with the same values as this TextStyle instance
   * @example
   * ```ts
   * const style = new TextStyle({
   *     fontSize: 24,
   *     fill: 0xff0000,
   *     stroke: { color: 0x0000ff, width: 2 }
   * });
   * const object = style.toObject();
   * console.log(object);
   * // { fontSize: 24, fill: 0xff0000, stroke: { color: 0x0000ff, width: 2 } }
   * ```
   */
  _toObject() {
    return {
      align: this.align,
      breakWords: this.breakWords,
      dropShadow: this._dropShadow ? { ...this._dropShadow } : null,
      fill: this._fill ? { ...this._fill } : void 0,
      fontFamily: this.fontFamily,
      fontSize: this.fontSize,
      fontStyle: this.fontStyle,
      fontVariant: this.fontVariant,
      fontWeight: this.fontWeight,
      leading: this.leading,
      letterSpacing: this.letterSpacing,
      lineHeight: this.lineHeight,
      padding: this.padding,
      stroke: this._stroke ? { ...this._stroke } : void 0,
      textBaseline: this.textBaseline,
      trim: this.trim,
      whiteSpace: this.whiteSpace,
      wordWrap: this.wordWrap,
      wordWrapWidth: this.wordWrapWidth,
      filters: this._filters ? [...this._filters] : void 0,
      tagStyles: this._tagStyles ? { ...this._tagStyles } : void 0
    };
  }
  /**
   * Creates a new TextStyle object with the same values as this one.
   * @returns New cloned TextStyle object
   */
  clone() {
    return new _TextStyle(this._toObject());
  }
  /**
   * Returns the final padding for the text style, taking into account any filters applied.
   * Used internally for correct measurements
   * @internal
   * @returns {number} The final padding for the text style.
   */
  _getFinalPadding() {
    let filterPadding = 0;
    if (this._filters) {
      for (let i = 0; i < this._filters.length; i++) {
        filterPadding += this._filters[i].padding;
      }
    }
    return Math.max(this._padding, filterPadding);
  }
  /**
   * Destroys this text style.
   * @param options - Options parameter. A boolean will act as if all options
   *  have been set to that value
   * @example
   * // Destroy the text style and its textures
   * textStyle.destroy({ texture: true, textureSource: true });
   * textStyle.destroy(true);
   */
  destroy(options = false) {
    this.removeAllListeners();
    const destroyTexture = typeof options === "boolean" ? options : options?.texture;
    if (destroyTexture) {
      const destroyTextureSource = typeof options === "boolean" ? options : options?.textureSource;
      if (this._fill?.texture) {
        this._fill.texture.destroy(destroyTextureSource);
      }
      if (this._originalFill?.texture) {
        this._originalFill.texture.destroy(destroyTextureSource);
      }
      if (this._stroke?.texture) {
        this._stroke.texture.destroy(destroyTextureSource);
      }
      if (this._originalStroke?.texture) {
        this._originalStroke.texture.destroy(destroyTextureSource);
      }
    }
    this._fill = null;
    this._stroke = null;
    this.dropShadow = null;
    this._originalStroke = null;
    this._originalFill = null;
  }
  _createProxy(value, cb) {
    return new Proxy(value, {
      set: (target, property, newValue) => {
        if (target[property] === newValue) return true;
        target[property] = newValue;
        cb?.(property, newValue);
        this.update();
        return true;
      }
    });
  }
  _isFillStyle(value) {
    return (value ?? null) !== null && !(Color.Color.isColorLike(value) || value instanceof FillGradient.FillGradient || value instanceof FillPattern.FillPattern);
  }
};
/**
 * Default drop shadow settings used when enabling drop shadows on text.
 * These values are used as the base configuration when drop shadows are enabled without specific settings.
 * @example
 * ```ts
 * // Customize default settings globally
 * TextStyle.defaultDropShadow.alpha = 0.5;    // 50% opacity for all shadows
 * TextStyle.defaultDropShadow.blur = 2;       // 2px blur for all shadows
 * TextStyle.defaultDropShadow.color = 'blue'; // Blue shadows by default
 * ```
 */
_TextStyle.defaultDropShadow = {
  alpha: 1,
  angle: Math.PI / 6,
  blur: 0,
  color: "black",
  distance: 5
};
/**
 * Default text style settings used when creating new text objects.
 * These values serve as the base configuration and can be customized globally.
 * @example
 * ```ts
 * // Customize default text style globally
 * TextStyle.defaultTextStyle.fontSize = 16;
 * TextStyle.defaultTextStyle.fill = 0x333333;
 * TextStyle.defaultTextStyle.fontFamily = ['Arial', 'Helvetica', 'sans-serif'];
 * ```
 */
_TextStyle.defaultTextStyle = {
  align: "left",
  breakWords: false,
  dropShadow: null,
  fill: "black",
  fontFamily: "Arial",
  fontSize: 26,
  fontStyle: "normal",
  fontVariant: "normal",
  fontWeight: "normal",
  leading: 0,
  letterSpacing: 0,
  lineHeight: 0,
  padding: 0,
  stroke: null,
  textBaseline: "alphabetic",
  trim: false,
  whiteSpace: "pre",
  wordWrap: false,
  wordWrapWidth: 100
};
let TextStyle = _TextStyle;
function convertV7Tov8Style(style) {
  const oldStyle = style;
  if (typeof oldStyle.dropShadow === "boolean" && oldStyle.dropShadow) {
    const defaults = TextStyle.defaultDropShadow;
    style.dropShadow = {
      alpha: oldStyle.dropShadowAlpha ?? defaults.alpha,
      angle: oldStyle.dropShadowAngle ?? defaults.angle,
      blur: oldStyle.dropShadowBlur ?? defaults.blur,
      color: oldStyle.dropShadowColor ?? defaults.color,
      distance: oldStyle.dropShadowDistance ?? defaults.distance
    };
  }
  if (oldStyle.strokeThickness !== void 0) {
    deprecation.deprecation(deprecation.v8_0_0, "strokeThickness is now a part of stroke");
    const color = oldStyle.stroke;
    let obj = {};
    if (Color.Color.isColorLike(color)) {
      obj.color = color;
    } else if (color instanceof FillGradient.FillGradient || color instanceof FillPattern.FillPattern) {
      obj.fill = color;
    } else if (Object.hasOwnProperty.call(color, "color") || Object.hasOwnProperty.call(color, "fill")) {
      obj = color;
    } else {
      throw new Error("Invalid stroke value.");
    }
    style.stroke = {
      ...obj,
      width: oldStyle.strokeThickness
    };
  }
  if (Array.isArray(oldStyle.fillGradientStops)) {
    deprecation.deprecation(deprecation.v8_0_0, "gradient fill is now a fill pattern: `new FillGradient(...)`");
    if (!Array.isArray(oldStyle.fill) || oldStyle.fill.length === 0) {
      throw new Error("Invalid fill value. Expected an array of colors for gradient fill.");
    }
    if (oldStyle.fill.length !== oldStyle.fillGradientStops.length) {
      warn.warn("The number of fill colors must match the number of fill gradient stops.");
    }
    const gradientFill = new FillGradient.FillGradient({
      start: { x: 0, y: 0 },
      end: { x: 0, y: 1 },
      textureSpace: "local"
    });
    const fillGradientStops = oldStyle.fillGradientStops.slice();
    const fills = oldStyle.fill.map((color) => Color.Color.shared.setValue(color).toNumber());
    fillGradientStops.forEach((stop, index) => {
      gradientFill.addColorStop(stop, fills[index]);
    });
    style.fill = {
      fill: gradientFill
    };
  }
}

exports.TextStyle = TextStyle;
//# sourceMappingURL=TextStyle.js.map
