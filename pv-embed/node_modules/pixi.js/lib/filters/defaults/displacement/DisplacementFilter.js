'use strict';

var Matrix = require('../../../maths/matrix/Matrix.js');
var Point = require('../../../maths/point/Point.js');
var GlProgram = require('../../../rendering/renderers/gl/shader/GlProgram.js');
var GpuProgram = require('../../../rendering/renderers/gpu/shader/GpuProgram.js');
var UniformGroup = require('../../../rendering/renderers/shared/shader/UniformGroup.js');
var Sprite = require('../../../scene/sprite/Sprite.js');
var deprecation = require('../../../utils/logging/deprecation.js');
var Filter = require('../../Filter.js');
var displacement = require('./displacement.frag.js');
var displacement$1 = require('./displacement.vert.js');
var displacement$2 = require('./displacement.wgsl.js');

"use strict";
class DisplacementFilter extends Filter.Filter {
  constructor(...args) {
    let options = args[0];
    if (options instanceof Sprite.Sprite) {
      if (args[1]) {
        deprecation.deprecation(deprecation.v8_0_0, "DisplacementFilter now uses options object instead of params. {sprite, scale}");
      }
      options = { sprite: options, scale: args[1] };
    }
    const { sprite, scale: scaleOption, ...rest } = options;
    let scale = scaleOption ?? 20;
    if (typeof scale === "number") {
      scale = new Point.Point(scale, scale);
    }
    const filterUniforms = new UniformGroup.UniformGroup({
      uFilterMatrix: { value: new Matrix.Matrix(), type: "mat3x3<f32>" },
      uScale: { value: scale, type: "vec2<f32>" },
      uRotation: { value: new Float32Array([0, 0, 0, 0]), type: "mat2x2<f32>" }
    });
    const glProgram = GlProgram.GlProgram.from({
      vertex: displacement$1.default,
      fragment: displacement.default,
      name: "displacement-filter"
    });
    const gpuProgram = GpuProgram.GpuProgram.from({
      vertex: {
        source: displacement$2.default,
        entryPoint: "mainVertex"
      },
      fragment: {
        source: displacement$2.default,
        entryPoint: "mainFragment"
      }
    });
    const textureSource = sprite.texture.source;
    super({
      ...rest,
      gpuProgram,
      glProgram,
      resources: {
        filterUniforms,
        uMapTexture: textureSource,
        uMapSampler: textureSource.style
      }
    });
    this._sprite = options.sprite;
    this._sprite.renderable = false;
  }
  /**
   * Applies the filter.
   * @param filterManager - The manager.
   * @param input - The input target.
   * @param output - The output target.
   * @param clearMode - clearMode.
   * @advanced
   */
  apply(filterManager, input, output, clearMode) {
    const uniforms = this.resources.filterUniforms.uniforms;
    filterManager.calculateSpriteMatrix(
      uniforms.uFilterMatrix,
      this._sprite
    );
    const wt = this._sprite.worldTransform;
    const lenX = Math.sqrt(wt.a * wt.a + wt.b * wt.b);
    const lenY = Math.sqrt(wt.c * wt.c + wt.d * wt.d);
    if (lenX !== 0 && lenY !== 0) {
      uniforms.uRotation[0] = wt.a / lenX;
      uniforms.uRotation[1] = wt.b / lenX;
      uniforms.uRotation[2] = wt.c / lenY;
      uniforms.uRotation[3] = wt.d / lenY;
    }
    this.resources.uMapTexture = this._sprite.texture.source;
    filterManager.applyFilter(this, input, output, clearMode);
  }
  /**
   * The scale of the displacement effect.
   *
   * Gets the current x and y scaling values used for the displacement mapping.
   * - x: Horizontal displacement scale
   * - y: Vertical displacement scale
   * @returns {Point} The current scale as a Point object
   * @example
   * ```ts
   * const filter = new DisplacementFilter({ sprite });
   *
   * // Get current scale
   * console.log(filter.scale.x, filter.scale.y);
   *
   * // Update scale
   * filter.scale.x = 100;
   * filter.scale.y = 50;
   * ```
   */
  get scale() {
    return this.resources.filterUniforms.uniforms.uScale;
  }
}

exports.DisplacementFilter = DisplacementFilter;
//# sourceMappingURL=DisplacementFilter.js.map
