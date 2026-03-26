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
class GpuMeshAdapter {
  init() {
    const gpuProgram = compileHighShaderToProgram.compileHighShaderGpuProgram({
      name: "mesh",
      bits: [
        localUniformBit.localUniformBit,
        textureBit.textureBit,
        roundPixelsBit.roundPixelsBit
      ]
    });
    this._shader = new Shader.Shader({
      gpuProgram,
      resources: {
        uTexture: Texture.Texture.EMPTY._source,
        uSampler: Texture.Texture.EMPTY._source.style,
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
      shader.groups[2] = renderer.texture.getTextureBindGroup(mesh.texture);
    } else if (!shader.gpuProgram) {
      warn.warn("Mesh shader has no gpuProgram", mesh.shader);
      return;
    }
    const gpuProgram = shader.gpuProgram;
    if (gpuProgram.autoAssignGlobalUniforms) {
      shader.groups[0] = renderer.globalUniforms.bindGroup;
    }
    if (gpuProgram.autoAssignLocalUniforms) {
      const localUniforms = meshPipe.localUniforms;
      shader.groups[1] = renderer.renderPipes.uniformBatch.getUniformBindGroup(localUniforms, true);
    }
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
/** @ignore */
GpuMeshAdapter.extension = {
  type: [
    Extensions.ExtensionType.WebGPUPipesAdaptor
  ],
  name: "mesh"
};

exports.GpuMeshAdapter = GpuMeshAdapter;
//# sourceMappingURL=GpuMeshAdapter.js.map
