import { TexturePool } from '../../../rendering/renderers/shared/texture/TexturePool.mjs';
import { RendererType } from '../../../rendering/renderers/types.mjs';
import { deprecation, v8_0_0 } from '../../../utils/logging/deprecation.mjs';
import { Filter } from '../../Filter.mjs';
import { BlurFilterPass } from './BlurFilterPass.mjs';

"use strict";
class BlurFilter extends Filter {
  constructor(...args) {
    let options = args[0] ?? {};
    if (typeof options === "number") {
      deprecation(v8_0_0, "BlurFilter constructor params are now options object. See params: { strength, quality, resolution, kernelSize }");
      options = { strength: options };
      if (args[1] !== void 0) options.quality = args[1];
      if (args[2] !== void 0) options.resolution = args[2] || "inherit";
      if (args[3] !== void 0) options.kernelSize = args[3];
    }
    options = { ...BlurFilterPass.defaultOptions, ...options };
    const { strength, strengthX, strengthY, quality, ...rest } = options;
    super({
      ...rest,
      compatibleRenderers: RendererType.BOTH,
      resources: {}
    });
    this._repeatEdgePixels = false;
    this.blurXFilter = new BlurFilterPass({ horizontal: true, ...options });
    this.blurYFilter = new BlurFilterPass({ horizontal: false, ...options });
    this.quality = quality;
    this.strengthX = strengthX ?? strength;
    this.strengthY = strengthY ?? strength;
    this.repeatEdgePixels = false;
  }
  /**
   * Applies the filter.
   * @param filterManager - The manager.
   * @param input - The input target.
   * @param output - The output target.
   * @param clearMode - How to clear
   * @advanced
   */
  apply(filterManager, input, output, clearMode) {
    const xStrength = Math.abs(this.blurXFilter.strength);
    const yStrength = Math.abs(this.blurYFilter.strength);
    if (xStrength && yStrength) {
      const tempTexture = TexturePool.getSameSizeTexture(input);
      this.blurXFilter.blendMode = "normal";
      this.blurXFilter.apply(filterManager, input, tempTexture, true);
      this.blurYFilter.blendMode = this.blendMode;
      this.blurYFilter.apply(filterManager, tempTexture, output, clearMode);
      TexturePool.returnTexture(tempTexture);
    } else if (yStrength) {
      this.blurYFilter.blendMode = this.blendMode;
      this.blurYFilter.apply(filterManager, input, output, clearMode);
    } else {
      this.blurXFilter.blendMode = this.blendMode;
      this.blurXFilter.apply(filterManager, input, output, clearMode);
    }
  }
  updatePadding() {
    if (this._repeatEdgePixels) {
      this.padding = 0;
    } else {
      this.padding = Math.max(Math.abs(this.blurXFilter.blur), Math.abs(this.blurYFilter.blur)) * 2;
    }
  }
  /**
   * Sets the strength of both the blurX and blurY properties simultaneously.
   * Controls the overall intensity of the Gaussian blur effect.
   * @example
   * ```ts
   * // Set equal blur strength for both axes
   * filter.strength = 8;
   *
   * // Will throw error if X and Y are different
   * filter.strengthX = 4;
   * filter.strengthY = 8;
   * filter.strength; // Error: BlurFilter's strengthX and strengthY are different
   * ```
   * @default 8
   * @throws {Error} If strengthX and strengthY are different values
   */
  get strength() {
    if (this.strengthX !== this.strengthY) {
      throw new Error("BlurFilter's strengthX and strengthY are different");
    }
    return this.strengthX;
  }
  set strength(value) {
    this.blurXFilter.blur = this.blurYFilter.blur = value;
    this.updatePadding();
  }
  /**
   * Sets the number of passes for blur. More passes means higher quality blurring.
   * Controls the precision and smoothness of the blur effect at the cost of performance.
   * @example
   * ```ts
   * // High quality blur (slower)
   * filter.quality = 8;
   *
   * // Low quality blur (faster)
   * filter.quality = 2;
   * ```
   * @default 4
   * @remarks Higher values produce better quality but impact performance
   */
  get quality() {
    return this.blurXFilter.quality;
  }
  set quality(value) {
    this.blurXFilter.quality = this.blurYFilter.quality = value;
  }
  /**
   * Sets the strength of horizontal blur.
   * Controls the blur intensity along the x-axis independently.
   * @example
   * ```ts
   * // Apply horizontal-only blur
   * filter.strengthX = 8;
   * filter.strengthY = 0;
   *
   * // Create motion blur effect
   * filter.strengthX = 16;
   * filter.strengthY = 2;
   * ```
   * @default 8
   */
  get strengthX() {
    return this.blurXFilter.blur;
  }
  set strengthX(value) {
    this.blurXFilter.blur = value;
    this.updatePadding();
  }
  /**
   * Sets the strength of the vertical blur.
   * Controls the blur intensity along the y-axis independently.
   * @example
   * ```ts
   * // Apply vertical-only blur
   * filter.strengthX = 0;
   * filter.strengthY = 8;
   *
   * // Create radial blur effect
   * filter.strengthX = 8;
   * filter.strengthY = 8;
   * ```
   * @default 8
   */
  get strengthY() {
    return this.blurYFilter.blur;
  }
  set strengthY(value) {
    this.blurYFilter.blur = value;
    this.updatePadding();
  }
  /**
   * Sets the strength of both the blurX and blurY properties simultaneously
   * @default 2
   * @deprecated since 8.3.0
   * @see BlurFilter.strength
   */
  get blur() {
    deprecation("8.3.0", "BlurFilter.blur is deprecated, please use BlurFilter.strength instead.");
    return this.strength;
  }
  set blur(value) {
    deprecation("8.3.0", "BlurFilter.blur is deprecated, please use BlurFilter.strength instead.");
    this.strength = value;
  }
  /**
   * Sets the strength of the blurX property
   * @default 2
   * @deprecated since 8.3.0
   * @see BlurFilter.strengthX
   */
  get blurX() {
    deprecation("8.3.0", "BlurFilter.blurX is deprecated, please use BlurFilter.strengthX instead.");
    return this.strengthX;
  }
  set blurX(value) {
    deprecation("8.3.0", "BlurFilter.blurX is deprecated, please use BlurFilter.strengthX instead.");
    this.strengthX = value;
  }
  /**
   * Sets the strength of the blurY property
   * @default 2
   * @deprecated since 8.3.0
   * @see BlurFilter.strengthY
   */
  get blurY() {
    deprecation("8.3.0", "BlurFilter.blurY is deprecated, please use BlurFilter.strengthY instead.");
    return this.strengthY;
  }
  set blurY(value) {
    deprecation("8.3.0", "BlurFilter.blurY is deprecated, please use BlurFilter.strengthY instead.");
    this.strengthY = value;
  }
  /**
   * If set to true the edge of the target will be clamped
   * @default false
   */
  get repeatEdgePixels() {
    return this._repeatEdgePixels;
  }
  set repeatEdgePixels(value) {
    this._repeatEdgePixels = value;
    this.updatePadding();
  }
}
/**
 * Default blur filter options
 * @example
 * ```ts
 * // Set default options for all BlurFilters
 * BlurFilter.defaultOptions = {
 *     strength: 10,       // Default blur strength
 *     quality: 2,        // Default blur quality
 *     kernelSize: 7      // Default kernel size
 * };
 * // Create a filter with these defaults
 * const filter = new BlurFilter(); // Uses default options
 * ```
 * @remarks
 * - These options are used when creating a new BlurFilter without specific parameters
 * - Can be overridden by passing options to the constructor
 * - Useful for setting global defaults for all blur filters in your application
 * @see {@link BlurFilterOptions} For detailed options
 * @see {@link BlurFilter} The filter that uses these options
 */
BlurFilter.defaultOptions = {
  /** The strength of the blur filter. */
  strength: 8,
  /** The quality of the blur filter. */
  quality: 4,
  /** The kernelSize of the blur filter.Options: 5, 7, 9, 11, 13, 15. */
  kernelSize: 5,
  /** Whether to use legacy blur pass behavior. */
  legacy: false
};

export { BlurFilter };
//# sourceMappingURL=BlurFilter.mjs.map
