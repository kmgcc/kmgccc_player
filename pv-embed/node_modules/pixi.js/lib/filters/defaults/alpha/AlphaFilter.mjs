import { GlProgram } from '../../../rendering/renderers/gl/shader/GlProgram.mjs';
import { GpuProgram } from '../../../rendering/renderers/gpu/shader/GpuProgram.mjs';
import { UniformGroup } from '../../../rendering/renderers/shared/shader/UniformGroup.mjs';
import { Filter } from '../../Filter.mjs';
import vertex from '../defaultFilter.vert.mjs';
import fragment from './alpha.frag.mjs';
import source from './alpha.wgsl.mjs';

"use strict";
const _AlphaFilter = class _AlphaFilter extends Filter {
  constructor(options) {
    options = { ..._AlphaFilter.defaultOptions, ...options };
    const gpuProgram = GpuProgram.from({
      vertex: {
        source,
        entryPoint: "mainVertex"
      },
      fragment: {
        source,
        entryPoint: "mainFragment"
      }
    });
    const glProgram = GlProgram.from({
      vertex,
      fragment,
      name: "alpha-filter"
    });
    const { alpha, ...rest } = options;
    const alphaUniforms = new UniformGroup({
      uAlpha: { value: alpha, type: "f32" }
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

export { AlphaFilter };
//# sourceMappingURL=AlphaFilter.mjs.map
