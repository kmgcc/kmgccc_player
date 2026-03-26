'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var Matrix = require('../../../maths/matrix/Matrix.js');
var compileHighShaderToProgram = require('../../../rendering/high-shader/compileHighShaderToProgram.js');
var localUniformBit = require('../../../rendering/high-shader/shader-bits/localUniformBit.js');
var roundPixelsBit = require('../../../rendering/high-shader/shader-bits/roundPixelsBit.js');
var textureBit = require('../../../rendering/high-shader/shader-bits/textureBit.js');
var Shader = require('../../../rendering/renderers/shared/shader/Shader.js');
var Texture = require('../../../rendering/renderers/shared/texture/Texture.js');
var warn = require('../../../utils/logging/warn.js');

"use strict";
class GlMeshAdaptor {
  init() {
    const glProgram = compileHighShaderToProgram.compileHighShaderGlProgram({
      name: "mesh",
      bits: [
        localUniformBit.localUniformBitGl,
        textureBit.textureBitGl,
        roundPixelsBit.roundPixelsBitGl
      ]
    });
    this._shader = new Shader.Shader({
      glProgram,
      resources: {
        uTexture: Texture.Texture.EMPTY.source,
        textureUniforms: {
          uTextureMatrix: { type: "mat3x3<f32>", value: new Matrix.Matrix() }
        }
      }
    });
  }
  execute(meshPipe, mesh) {
    const renderer = meshPipe.renderer;
    let shader = mesh._shader;
    if (!shader) {
      shader = this._shader;
      const texture = mesh.texture;
      const source = texture.source;
      shader.resources.uTexture = source;
      shader.resources.uSampler = source.style;
      shader.resources.textureUniforms.uniforms.uTextureMatrix = texture.textureMatrix.mapCoord;
    } else if (!shader.glProgram) {
      warn.warn("Mesh shader has no glProgram", mesh.shader);
      return;
    }
    shader.groups[100] = renderer.globalUniforms.bindGroup;
    shader.groups[101] = meshPipe.localUniformsBindGroup;
    renderer.encoder.draw({
      geometry: mesh._geometry,
      shader,
      state: mesh.state
    });
  }
  destroy() {
    this._shader.destroy(true);
    this._shader = null;
  }
}
GlMeshAdaptor.extension = {
  type: [
    Extensions.ExtensionType.WebGLPipesAdaptor
  ],
  name: "mesh"
};

exports.GlMeshAdaptor = GlMeshAdaptor;
//# sourceMappingURL=GlMeshAdaptor.js.map
