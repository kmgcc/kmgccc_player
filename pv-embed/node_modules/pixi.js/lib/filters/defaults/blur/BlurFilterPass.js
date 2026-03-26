'use strict';

var TexturePool = require('../../../rendering/renderers/shared/texture/TexturePool.js');
var types = require('../../../rendering/renderers/types.js');
var Filter = require('../../Filter.js');
var generateBlurGlProgram = require('./gl/generateBlurGlProgram.js');
var generateBlurProgram = require('./gpu/generateBlurProgram.js');

"use strict";
const _BlurFilterPass = class _BlurFilterPass extends Filter.Filter {
  /**
   * @param options
   * @param options.horizontal - Do pass along the x-axis (`true`) or y-axis (`false`).
   * @param options.strength - The strength of the blur filter.
   * @param options.quality - The quality of the blur filter.
   * @param options.kernelSize - The kernelSize of the blur filter.Options: 5, 7, 9, 11, 13, 15.
   */
  constructor(options) {
    options = { ..._BlurFilterPass.defaultOptions, ...options };
    const glProgram = generateBlurGlProgram.generateBlurGlProgram(options.horizontal, options.kernelSize);
    const gpuProgram = generateBlurProgram.generateBlurProgram(options.horizontal, options.kernelSize);
    super({
      glProgram,
      gpuProgram,
      resources: {
        blurUniforms: {
          uStrength: { value: 0, type: "f32" }
        }
      },
      ...options
    });
    this.horizontal = options.horizontal;
    this.legacy = options.legacy ?? false;
    this._quality = 0;
    this.quality = options.quality;
    this.blur = options.strength;
    this._blurUniforms = this.resources.blurUniforms;
    this._uniforms = this._blurUniforms.uniforms;
  }
  /**
   * Applies the filter.
   * @param filterManager - The manager.
   * @param input - The input target.
   * @param output - The output target.
   * @param clearMode - How to clear
   */
  apply(filterManager, input, output, clearMode) {
    if (this.legacy) {
      this._applyLegacy(filterManager, input, output, clearMode);
    } else {
      this._applyOptimized(filterManager, input, output, clearMode);
    }
  }
  _applyLegacy(filterManager, input, output, clearMode) {
    this._uniforms.uStrength = this.strength / this.passes;
    if (this.passes === 1) {
      filterManager.applyFilter(this, input, output, clearMode);
    } else {
      const tempTexture = TexturePool.TexturePool.getSameSizeTexture(input);
      let flip = input;
      let flop = tempTexture;
      this._state.blend = false;
      const shouldClear = filterManager.renderer.type === types.RendererType.WEBGPU;
      for (let i = 0; i < this.passes - 1; i++) {
        filterManager.applyFilter(this, flip, flop, i === 0 ? true : shouldClear);
        const temp = flop;
        flop = flip;
        flip = temp;
      }
      this._state.blend = true;
      filterManager.applyFilter(this, flip, output, clearMode);
      TexturePool.TexturePool.returnTexture(tempTexture);
    }
  }
  _applyOptimized(filterManager, input, output, clearMode) {
    this._uniforms.uStrength = this._calculateInitialStrength();
    if (this.passes === 1) {
      filterManager.applyFilter(this, input, output, clearMode);
    } else {
      const tempTexture = TexturePool.TexturePool.getSameSizeTexture(input);
      let flip = input;
      let flop = tempTexture;
      this._state.blend = false;
      const renderer = filterManager.renderer;
      const isWebGPU = renderer.type === types.RendererType.WEBGPU;
      const uboBatcher = isWebGPU ? renderer.renderPipes.uniformBatch : null;
      for (let i = 0; i < this.passes - 1; i++) {
        if (uboBatcher) {
          this.groups[1].setResource(uboBatcher.getUboResource(this._blurUniforms), 0);
        }
        filterManager.applyFilter(this, flip, flop, isWebGPU);
        const temp = flop;
        flop = flip;
        flip = temp;
        this._uniforms.uStrength *= 0.5;
      }
      if (uboBatcher) {
        this.groups[1].setResource(uboBatcher.getUboResource(this._blurUniforms), 0);
      }
      this._state.blend = true;
      filterManager.applyFilter(this, flip, output, clearMode);
      TexturePool.TexturePool.returnTexture(tempTexture);
    }
  }
  /**
   * Calculates the initial strength for the first blur pass so that the combined
   * effect of all passes matches the filter's target strength.
   *
   * Uses variance addition property: for Gaussian blurs, σ_combined² = Σσᵢ²
   * With halving scheme (s, s/2, s/4, ...), sum of squared coefficients = 4/3
   */
  _calculateInitialStrength() {
    let sumOfSquares = 1;
    let coefficient = 0.5;
    for (let i = 1; i < this.passes; i++) {
      sumOfSquares += coefficient * coefficient;
      coefficient *= 0.5;
    }
    return this.strength / Math.sqrt(sumOfSquares);
  }
  /**
   * Sets the strength of both the blur.
   * @default 16
   */
  get blur() {
    return this.strength;
  }
  set blur(value) {
    this.padding = 1 + Math.abs(value) * 2;
    this.strength = value;
  }
  /**
   * Sets the quality of the blur by modifying the number of passes. More passes means higher
   * quality blurring but the lower the performance.
   * @default 4
   */
  get quality() {
    return this._quality;
  }
  set quality(value) {
    this._quality = value;
    this.passes = value;
  }
};
/** Default blur filter pass options */
_BlurFilterPass.defaultOptions = {
  /** The strength of the blur filter. */
  strength: 8,
  /** The quality of the blur filter. */
  quality: 4,
  /** The kernelSize of the blur filter.Options: 5, 7, 9, 11, 13, 15. */
  kernelSize: 5,
  /** Whether to use legacy blur pass behavior. */
  legacy: false
};
let BlurFilterPass = _BlurFilterPass;

exports.BlurFilterPass = BlurFilterPass;
//# sourceMappingURL=BlurFilterPass.js.map
