import { Color } from '../../../../color/Color.mjs';
import { DOMAdapter } from '../../../../environment/adapter.mjs';
import { Matrix } from '../../../../maths/matrix/Matrix.mjs';
import { ImageSource } from '../../../../rendering/renderers/shared/texture/sources/ImageSource.mjs';
import { Texture } from '../../../../rendering/renderers/shared/texture/Texture.mjs';
import { uid } from '../../../../utils/data/uid.mjs';
import { deprecation } from '../../../../utils/logging/deprecation.mjs';
import { definedProps } from '../../../container/utils/definedProps.mjs';

"use strict";
const emptyColorStops = [{ offset: 0, color: "white" }, { offset: 1, color: "black" }];
const _FillGradient = class _FillGradient {
  constructor(...args) {
    /**
     * Unique identifier for this gradient instance
     * @internal
     */
    this.uid = uid("fillGradient");
    /**
     * Internal tick counter to track changes in the gradient.
     * This is used to invalidate the gradient when the texture changes.
     * @internal
     */
    this._tick = 0;
    /** Type of gradient - currently only supports 'linear' */
    this.type = "linear";
    /** Array of color stops defining the gradient */
    this.colorStops = [];
    let options = ensureGradientOptions(args);
    const defaults = options.type === "radial" ? _FillGradient.defaultRadialOptions : _FillGradient.defaultLinearOptions;
    options = { ...defaults, ...definedProps(options) };
    this._textureSize = options.textureSize;
    this._wrapMode = options.wrapMode;
    if (options.type === "radial") {
      this.center = options.center;
      this.outerCenter = options.outerCenter ?? this.center;
      this.innerRadius = options.innerRadius;
      this.outerRadius = options.outerRadius;
      this.scale = options.scale;
      this.rotation = options.rotation;
    } else {
      this.start = options.start;
      this.end = options.end;
    }
    this.textureSpace = options.textureSpace;
    this.type = options.type;
    options.colorStops.forEach((stop) => {
      this.addColorStop(stop.offset, stop.color);
    });
  }
  /**
   * Adds a color stop to the gradient
   * @param offset - Position of the stop (0-1)
   * @param color - Color of the stop
   * @returns This gradient instance for chaining
   */
  addColorStop(offset, color) {
    this.colorStops.push({ offset, color: Color.shared.setValue(color).toHexa() });
    return this;
  }
  /**
   * Builds the internal texture and transform for the gradient.
   * Called automatically when the gradient is first used.
   * @internal
   */
  buildLinearGradient() {
    if (this.texture) return;
    let { x: x0, y: y0 } = this.start;
    let { x: x1, y: y1 } = this.end;
    let dx = x1 - x0;
    let dy = y1 - y0;
    const flip = dx < 0 || dy < 0;
    if (this._wrapMode === "clamp-to-edge") {
      if (dx < 0) {
        const temp = x0;
        x0 = x1;
        x1 = temp;
        dx *= -1;
      }
      if (dy < 0) {
        const temp = y0;
        y0 = y1;
        y1 = temp;
        dy *= -1;
      }
    }
    const colorStops = this.colorStops.length ? this.colorStops : emptyColorStops;
    const defaultSize = this._textureSize;
    const { canvas, context } = getCanvas(defaultSize, 1);
    const gradient = !flip ? context.createLinearGradient(0, 0, this._textureSize, 0) : context.createLinearGradient(this._textureSize, 0, 0, 0);
    addColorStops(gradient, colorStops);
    context.fillStyle = gradient;
    context.fillRect(0, 0, defaultSize, 1);
    this.texture = new Texture({
      source: new ImageSource({
        resource: canvas,
        addressMode: this._wrapMode
      })
    });
    const dist = Math.sqrt(dx * dx + dy * dy);
    const angle = Math.atan2(dy, dx);
    const m = new Matrix();
    m.scale(dist / defaultSize, 1);
    m.rotate(angle);
    m.translate(x0, y0);
    if (this.textureSpace === "local") {
      m.scale(defaultSize, defaultSize);
    }
    this.transform = m;
  }
  /**
   * Builds the internal texture and transform for the gradient.
   * Called automatically when the gradient is first used.
   * @internal
   */
  buildGradient() {
    if (!this.texture) this._tick++;
    if (this.type === "linear") {
      this.buildLinearGradient();
    } else {
      this.buildRadialGradient();
    }
  }
  /**
   * Builds the internal texture and transform for the radial gradient.
   * Called automatically when the gradient is first used.
   * @internal
   */
  buildRadialGradient() {
    if (this.texture) return;
    const colorStops = this.colorStops.length ? this.colorStops : emptyColorStops;
    const defaultSize = this._textureSize;
    const { canvas, context } = getCanvas(defaultSize, defaultSize);
    const { x: x0, y: y0 } = this.center;
    const { x: x1, y: y1 } = this.outerCenter;
    const r0 = this.innerRadius;
    const r1 = this.outerRadius;
    const ox = x1 - r1;
    const oy = y1 - r1;
    const scale = defaultSize / (r1 * 2);
    const cx = (x0 - ox) * scale;
    const cy = (y0 - oy) * scale;
    const gradient = context.createRadialGradient(
      cx,
      cy,
      r0 * scale,
      (x1 - ox) * scale,
      (y1 - oy) * scale,
      r1 * scale
    );
    addColorStops(gradient, colorStops);
    context.fillStyle = colorStops[colorStops.length - 1].color;
    context.fillRect(0, 0, defaultSize, defaultSize);
    context.fillStyle = gradient;
    context.translate(cx, cy);
    context.rotate(this.rotation);
    context.scale(1, this.scale);
    context.translate(-cx, -cy);
    context.fillRect(0, 0, defaultSize, defaultSize);
    this.texture = new Texture({
      source: new ImageSource({
        resource: canvas,
        addressMode: this._wrapMode
      })
    });
    const m = new Matrix();
    m.scale(1 / scale, 1 / scale);
    m.translate(ox, oy);
    if (this.textureSpace === "local") {
      m.scale(defaultSize, defaultSize);
    }
    this.transform = m;
  }
  /** Destroys the gradient, releasing resources. This will also destroy the internal texture. */
  destroy() {
    this.texture?.destroy(true);
    this.texture = null;
    this.transform = null;
    this.colorStops = [];
    this.start = null;
    this.end = null;
    this.center = null;
    this.outerCenter = null;
  }
  /**
   * Returns a unique key for this gradient instance.
   * This key is used for caching and texture management.
   * @returns {string} Unique key for the gradient
   */
  get styleKey() {
    return `fill-gradient-${this.uid}-${this._tick}`;
  }
};
/** Default options for creating a gradient fill */
_FillGradient.defaultLinearOptions = {
  start: { x: 0, y: 0 },
  end: { x: 0, y: 1 },
  colorStops: [],
  textureSpace: "local",
  type: "linear",
  textureSize: 256,
  wrapMode: "clamp-to-edge"
};
/** Default options for creating a radial gradient fill */
_FillGradient.defaultRadialOptions = {
  center: { x: 0.5, y: 0.5 },
  innerRadius: 0,
  outerRadius: 0.5,
  colorStops: [],
  scale: 1,
  textureSpace: "local",
  type: "radial",
  textureSize: 256,
  wrapMode: "clamp-to-edge"
};
let FillGradient = _FillGradient;
function addColorStops(gradient, colorStops) {
  for (let i = 0; i < colorStops.length; i++) {
    const stop = colorStops[i];
    gradient.addColorStop(stop.offset, stop.color);
  }
}
function getCanvas(width, height) {
  const canvas = DOMAdapter.get().createCanvas(width, height);
  const context = canvas.getContext("2d");
  return { canvas, context };
}
function ensureGradientOptions(args) {
  let options = args[0] ?? {};
  if (typeof options === "number" || args[1]) {
    deprecation("8.5.2", `use options object instead`);
    options = {
      type: "linear",
      start: { x: args[0], y: args[1] },
      end: { x: args[2], y: args[3] },
      textureSpace: args[4],
      textureSize: args[5] ?? FillGradient.defaultLinearOptions.textureSize
    };
  }
  return options;
}

export { FillGradient };
//# sourceMappingURL=FillGradient.mjs.map
