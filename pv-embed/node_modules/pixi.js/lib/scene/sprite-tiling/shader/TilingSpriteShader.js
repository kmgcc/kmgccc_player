'use strict';

var Matrix = require('../../../maths/matrix/Matrix.js');
var compileHighShaderToProgram = require('../../../rendering/high-shader/compileHighShaderToProgram.js');
var localUniformBit = require('../../../rendering/high-shader/shader-bits/localUniformBit.js');
var roundPixelsBit = require('../../../rendering/high-shader/shader-bits/roundPixelsBit.js');
var Shader = require('../../../rendering/renderers/shared/shader/Shader.js');
var UniformGroup = require('../../../rendering/renderers/shared/shader/UniformGroup.js');
var Texture = require('../../../rendering/renderers/shared/texture/Texture.js');
var tilingBit = require('./tilingBit.js');

"use strict";
let gpuProgram;
let glProgram;
class TilingSpriteShader extends Shader.Shader {
  constructor() {
    gpuProgram ?? (gpuProgram = compileHighShaderToProgram.compileHighShaderGpuProgram({
      name: "tiling-sprite-shader",
      bits: [
        localUniformBit.localUniformBit,
        tilingBit.tilingBit,
        roundPixelsBit.roundPixelsBit
      ]
    }));
    glProgram ?? (glProgram = compileHighShaderToProgram.compileHighShaderGlProgram({
      name: "tiling-sprite-shader",
      bits: [
        localUniformBit.localUniformBitGl,
        tilingBit.tilingBitGl,
        roundPixelsBit.roundPixelsBitGl
      ]
    }));
    const tilingUniforms = new UniformGroup.UniformGroup({
      uMapCoord: { value: new Matrix.Matrix(), type: "mat3x3<f32>" },
      uClampFrame: { value: new Float32Array([0, 0, 1, 1]), type: "vec4<f32>" },
      uClampOffset: { value: new Float32Array([0, 0]), type: "vec2<f32>" },
      uTextureTransform: { value: new Matrix.Matrix(), type: "mat3x3<f32>" },
      uSizeAnchor: { value: new Float32Array([100, 100, 0.5, 0.5]), type: "vec4<f32>" }
    });
    super({
      glProgram,
      gpuProgram,
      resources: {
        localUniforms: new UniformGroup.UniformGroup({
          uTransformMatrix: { value: new Matrix.Matrix(), type: "mat3x3<f32>" },
          uColor: { value: new Float32Array([1, 1, 1, 1]), type: "vec4<f32>" },
          uRound: { value: 0, type: "f32" }
        }),
        tilingUniforms,
        uTexture: Texture.Texture.EMPTY.source,
        uSampler: Texture.Texture.EMPTY.source.style
      }
    });
  }
  updateUniforms(width, height, matrix, anchorX, anchorY, texture) {
    const tilingUniforms = this.resources.tilingUniforms;
    const textureWidth = texture.width;
    const textureHeight = texture.height;
    const textureMatrix = texture.textureMatrix;
    const uTextureTransform = tilingUniforms.uniforms.uTextureTransform;
    uTextureTransform.set(
      matrix.a * textureWidth / width,
      matrix.b * textureWidth / height,
      matrix.c * textureHeight / width,
      matrix.d * textureHeight / height,
      matrix.tx / width,
      matrix.ty / height
    );
    uTextureTransform.invert();
    tilingUniforms.uniforms.uMapCoord = textureMatrix.mapCoord;
    tilingUniforms.uniforms.uClampFrame = textureMatrix.uClampFrame;
    tilingUniforms.uniforms.uClampOffset = textureMatrix.uClampOffset;
    tilingUniforms.uniforms.uTextureTransform = uTextureTransform;
    tilingUniforms.uniforms.uSizeAnchor[0] = width;
    tilingUniforms.uniforms.uSizeAnchor[1] = height;
    tilingUniforms.uniforms.uSizeAnchor[2] = anchorX;
    tilingUniforms.uniforms.uSizeAnchor[3] = anchorY;
    if (texture) {
      this.resources.uTexture = texture.source;
      this.resources.uSampler = texture.source.style;
    }
  }
}

exports.TilingSpriteShader = TilingSpriteShader;
//# sourceMappingURL=TilingSpriteShader.js.map
