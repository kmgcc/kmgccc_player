'use strict';

var GlProgram = require('../../../rendering/renderers/gl/shader/GlProgram.js');
var GpuProgram = require('../../../rendering/renderers/gpu/shader/GpuProgram.js');
var UniformGroup = require('../../../rendering/renderers/shared/shader/UniformGroup.js');
var Filter = require('../../Filter.js');
var defaultFilter = require('../defaultFilter.vert.js');
var alpha$1 = require('./alpha.frag.js');
var alpha = require('./alpha.wgsl.js');

"use strict";
const _AlphaFilter = class _AlphaFilter extends Filter.Filter {
  constructor(options) {
    options = { ..._AlphaFilter.defaultOptions, ...options };
    const gpuProgram = GpuProgram.GpuProgram.from({
      vertex: {
        source: alpha.default,
        entryPoint: "mainVertex"
      },
      fragment: {
        source: alpha.default,
        entryPoint: "mainFragment"
      }
    });
    const glProgram = GlProgram.GlProgram.from({
      vertex: defaultFilter.default,
      fragment: alpha$1.default,
      name: "alpha-filter"
    });
    const { alpha: alpha$2, ...rest } = options;
    const alphaUniforms = new UniformGroup.UniformGroup({
      uAlpha: { value: alpha$2, type: "f32" }
    });
    super({
      ...rest,
      gpuProgram,
      glProgram,
      resources: {
        alphaUniforms
      }
    });
  }
  /**
   * The alpha value of the filter.
   * Controls the transparency of the filtered display object.
   * @example
   * ```ts
   * // Create filter with initial alpha
   * const filter = new AlphaFilter({ alpha: 0.5 });
   *
   * // Update alpha value dynamically
   * filter.alpha = 0.8;
   * ```
   * @default 1
   * @remarks
   * - 0 = fully transparent
   * - 1 = fully opaque
   * - Values are clamped between 0 and 1
   */
  get alpha() {
    return this.resources.alphaUniforms.uniforms.uAlpha;
  }
  set alpha(value) {
    this.resources.alphaUniforms.uniforms.uAlpha = value;
  }
};
/**
 * Default options for the AlphaFilter.
 * @example
 * ```ts
 * AlphaFilter.defaultOptions = {
 *     alpha: 0.5, // Default alpha value
 * };
 * // Use default options
 * const filter = new AlphaFilter(); // Uses default alpha of 0.5
 * ```
 */
_AlphaFilter.defaultOptions = {
  /**
   * Amount of alpha transparency to apply.
   * - 0 = fully transparent
   * - 1 = fully opaque (default)
   * @default 1
   */
  alpha: 1
};
let AlphaFilter = _AlphaFilter;

exports.AlphaFilter = AlphaFilter;
//# sourceMappingURL=AlphaFilter.js.map
