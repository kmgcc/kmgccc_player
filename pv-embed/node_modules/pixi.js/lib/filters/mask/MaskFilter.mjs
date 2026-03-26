import { Matrix } from '../../maths/matrix/Matrix.mjs';
import { GlProgram } from '../../rendering/renderers/gl/shader/GlProgram.mjs';
import { GpuProgram } from '../../rendering/renderers/gpu/shader/GpuProgram.mjs';
import { UniformGroup } from '../../rendering/renderers/shared/shader/UniformGroup.mjs';
import { TextureMatrix } from '../../rendering/renderers/shared/texture/TextureMatrix.mjs';
import { Filter } from '../Filter.mjs';
import fragment from './mask.frag.mjs';
import vertex from './mask.vert.mjs';
import source from './mask.wgsl.mjs';

"use strict";
class MaskFilter extends Filter {
  constructor(options) {
    const { sprite, ...rest } = options;
    const textureMatrix = new TextureMatrix(sprite.texture);
    const filterUniforms = new UniformGroup({
      uFilterMatrix: { value: new Matrix(), type: "mat3x3<f32>" },
      uMaskClamp: { value: textureMatrix.uClampFrame, type: "vec4<f32>" },
      uAlpha: { value: 1, type: "f32" },
      uInverse: { value: options.inverse ? 1 : 0, type: "f32" }
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
    const glProgram = GlProgram.from({
      vertex,
      fragment,
      name: "mask-filter"
    });
    super({
      ...rest,
      gpuProgram,
      glProgram,
      clipToViewport: false,
      resources: {
        filterUniforms,
        uMaskTexture: sprite.texture.source
      }
    });
    this.sprite = sprite;
    this._textureMatrix = textureMatrix;
  }
  set inverse(value) {
    this.resources.filterUniforms.uniforms.uInverse = value ? 1 : 0;
  }
  get inverse() {
    return this.resources.filterUniforms.uniforms.uInverse === 1;
  }
  apply(filterManager, input, output, clearMode) {
    this._textureMatrix.texture = this.sprite.texture;
    filterManager.calculateSpriteMatrix(
      this.resources.filterUniforms.uniforms.uFilterMatrix,
      this.sprite
    ).prepend(this._textureMatrix.mapCoord);
    this.resources.uMaskTexture = this.sprite.texture.source;
    filterManager.applyFilter(this, input, output, clearMode);
  }
}

export { MaskFilter };
//# sourceMappingURL=MaskFilter.mjs.map
