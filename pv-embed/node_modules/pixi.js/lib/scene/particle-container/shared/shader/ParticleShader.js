'use strict';

var Color = require('../../../../color/Color.js');
var Matrix = require('../../../../maths/matrix/Matrix.js');
var GlProgram = require('../../../../rendering/renderers/gl/shader/GlProgram.js');
var GpuProgram = require('../../../../rendering/renderers/gpu/shader/GpuProgram.js');
var Shader = require('../../../../rendering/renderers/shared/shader/Shader.js');
var Texture = require('../../../../rendering/renderers/shared/texture/Texture.js');
var TextureStyle = require('../../../../rendering/renderers/shared/texture/TextureStyle.js');
var particles = require('./particles.frag.js');
var particles$1 = require('./particles.vert.js');
var particles$2 = require('./particles.wgsl.js');

"use strict";
class ParticleShader extends Shader.Shader {
  constructor() {
    const glProgram = GlProgram.GlProgram.from({
      vertex: particles$1.default,
      fragment: particles.default
    });
    const gpuProgram = GpuProgram.GpuProgram.from({
      fragment: {
        source: particles$2.default,
        entryPoint: "mainFragment"
      },
      vertex: {
        source: particles$2.default,
        entryPoint: "mainVertex"
      }
    });
    super({
      glProgram,
      gpuProgram,
      resources: {
        // this will be replaced with the texture from the particle container
        uTexture: Texture.Texture.WHITE.source,
        // this will be replaced with the texture style from the particle container
        uSampler: new TextureStyle.TextureStyle({}),
        // this will be replaced with the local uniforms from the particle container
        uniforms: {
          uTranslationMatrix: { value: new Matrix.Matrix(), type: "mat3x3<f32>" },
          uColor: { value: new Color.Color(16777215), type: "vec4<f32>" },
          uRound: { value: 1, type: "f32" },
          uResolution: { value: [0, 0], type: "vec2<f32>" }
        }
      }
    });
  }
}

exports.ParticleShader = ParticleShader;
//# sourceMappingURL=ParticleShader.js.map
