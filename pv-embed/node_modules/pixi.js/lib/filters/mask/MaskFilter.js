'use strict';

var Matrix = require('../../maths/matrix/Matrix.js');
var GlProgram = require('../../rendering/renderers/gl/shader/GlProgram.js');
var GpuProgram = require('../../rendering/renderers/gpu/shader/GpuProgram.js');
var UniformGroup = require('../../rendering/renderers/shared/shader/UniformGroup.js');
var TextureMatrix = require('../../rendering/renderers/shared/texture/TextureMatrix.js');
var Filter = require('../Filter.js');
var mask$1 = require('./mask.frag.js');
var mask$2 = require('./mask.vert.js');
var mask = require('./mask.wgsl.js');

"use strict";
class MaskFilter extends Filter.Filter {
  constructor(options) {
    const { sprite, ...rest } = options;
    const textureMatrix = new TextureMatrix.TextureMatrix(sprite.texture);
    const filterUniforms = new UniformGroup.UniformGroup({
      uFilterMatrix: { value: new Matrix.Matrix(), type: "mat3x3<f32>" },
      uMaskClamp: { value: textureMatrix.uClampFrame, type: "vec4<f32>" },
      uAlpha: { value: 1, type: "f32" },
      uInverse: { value: options.inverse ? 1 : 0, type: "f32" }
    });
    const gpuProgram = GpuProgram.GpuProgram.from({
      vertex: {
        source: mask.default,
        entryPoint: "mainVertex"
      },
      fragment: {
        source: mask.default,
        entryPoint: "mainFragment"
      }
    });
    const glProgram = GlProgram.GlProgram.from({
      vertex: mask$2.default,
      fragment: mask$1.default,
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

exports.MaskFilter = MaskFilter;
//# sourceMappingURL=MaskFilter.js.map
