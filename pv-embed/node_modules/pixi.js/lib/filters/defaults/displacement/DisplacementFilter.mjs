import { Matrix } from '../../../maths/matrix/Matrix.mjs';
import { Point } from '../../../maths/point/Point.mjs';
import { GlProgram } from '../../../rendering/renderers/gl/shader/GlProgram.mjs';
import { GpuProgram } from '../../../rendering/renderers/gpu/shader/GpuProgram.mjs';
import { UniformGroup } from '../../../rendering/renderers/shared/shader/UniformGroup.mjs';
import { Sprite } from '../../../scene/sprite/Sprite.mjs';
import { deprecation, v8_0_0 } from '../../../utils/logging/deprecation.mjs';
import { Filter } from '../../Filter.mjs';
import fragment from './displacement.frag.mjs';
import vertex from './displacement.vert.mjs';
import source from './displacement.wgsl.mjs';

"use strict";
class DisplacementFilter extends Filter {
  constructor(...args) {
    let options = args[0];
    if (options instanceof Sprite) {
      if (args[1]) {
        deprecation(v8_0_0, "DisplacementFilter now uses options object instead of params. {sprite, scale}");
      }
      options = { sprite: options, scale: args[1] };
    }
    const { sprite, scale: scaleOption, ...rest } = options;
    let scale = scaleOption ?? 20;
    if (typeof scale === "number") {
      scale = new Point(scale, scale);
    }
    const filterUniforms = new UniformGroup({
      uFilterMatrix: { value: new Matrix(), type: "mat3x3<f32>" },
      uScale: { value: scale, type: "vec2<f32>" },
      uRotation: { value: new Float32Array([0, 0, 0, 0]), type: "mat2x2<f32>" }
    });
    const glProgram = GlProgram.from({
      vertex,
      fragment,
      name: "displacement-filter"
    });
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

export { DisplacementFilter };
//# sourceMappingURL=DisplacementFilter.mjs.map
