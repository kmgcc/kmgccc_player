'use strict';

var GlProgram = require('../../../rendering/renderers/gl/shader/GlProgram.js');
var GpuProgram = require('../../../rendering/renderers/gpu/shader/GpuProgram.js');
var UniformGroup = require('../../../rendering/renderers/shared/shader/UniformGroup.js');
var Filter = require('../../Filter.js');
var defaultFilter = require('../defaultFilter.vert.js');
var noise$1 = require('./noise.frag.js');
var noise = require('./noise.wgsl.js');

"use strict";
const _NoiseFilter = class _NoiseFilter extends Filter.Filter {
  /**
   * @param options - The options of the noise filter.
   */
  constructor(options = {}) {
    options = { ..._NoiseFilter.defaultOptions, ...options };
    const gpuProgram = GpuProgram.GpuProgram.from({
      vertex: {
        source: noise.default,
        entryPoint: "mainVertex"
      },
      fragment: {
        source: noise.default,
        entryPoint: "mainFragment"
      }
    });
    const glProgram = GlProgram.GlProgram.from({
      vertex: defaultFilter.default,
      fragment: noise$1.default,
      name: "noise-filter"
    });
    const { noise: noise$2, seed, ...rest } = options;
    super({
      ...rest,
      gpuProgram,
      glProgram,
      resources: {
        noiseUniforms: new UniformGroup.UniformGroup({
          uNoise: { value: 1, type: "f32" },
          uSeed: { value: 1, type: "f32" }
        })
      }
    });
    this.noise = noise$2;
    this.seed = seed ?? Math.random();
  }
  /**
   * The amount of noise to apply to the filtered content.
   *
   * This value controls the intensity of the random noise effect:
   * - Values close to 0 produce subtle noise
   * - Values around 0.5 produce moderate noise
   * - Values close to 1 produce strong noise
   * @default 0.5
   * @example
   * ```ts
   * const noiseFilter = new NoiseFilter();
   *
   * // Set to subtle noise
   * noiseFilter.noise = 0.2;
   *
   * // Set to maximum noise
   * noiseFilter.noise = 1.0;
   * ```
   */
  get noise() {
    return this.resources.noiseUniforms.uniforms.uNoise;
  }
  set noise(value) {
    this.resources.noiseUniforms.uniforms.uNoise = value;
  }
  /**
   * The seed value used for random noise generation.
   *
   * This value determines the noise pattern:
   * - Using the same seed will generate identical noise patterns
   * - Different seeds produce different but consistent patterns
   * - `Math.random()` can be used for random patterns
   * @default Math.random()
   * @example
   * ```ts
   * const noiseFilter = new NoiseFilter();
   *
   * // Use a fixed seed for consistent noise
   * noiseFilter.seed = 12345;
   *
   * // Generate new random pattern
   * noiseFilter.seed = Math.random();
   * ```
   */
  get seed() {
    return this.resources.noiseUniforms.uniforms.uSeed;
  }
  set seed(value) {
    this.resources.noiseUniforms.uniforms.uSeed = value;
  }
};
/**
 * The default configuration options for the NoiseFilter.
 *
 * These values will be used when no specific options are provided to the constructor.
 * You can override any of these values by passing your own options object.
 * @example
 * ```ts
 * NoiseFilter.defaultOptions.noise = 0.7; // Change default noise to 0.7
 * const filter = new NoiseFilter(); // Will use noise 0.7 by default
 * ```
 */
_NoiseFilter.defaultOptions = {
  noise: 0.5
};
let NoiseFilter = _NoiseFilter;

exports.NoiseFilter = NoiseFilter;
//# sourceMappingURL=NoiseFilter.js.map
