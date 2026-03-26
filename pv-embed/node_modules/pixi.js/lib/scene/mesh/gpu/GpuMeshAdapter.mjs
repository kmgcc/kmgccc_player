import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { Matrix } from '../../../maths/matrix/Matrix.mjs';
import { compileHighShaderGpuProgram } from '../../../rendering/high-shader/compileHighShaderToProgram.mjs';
import { localUniformBit } from '../../../rendering/high-shader/shader-bits/localUniformBit.mjs';
import { roundPixelsBit } from '../../../rendering/high-shader/shader-bits/roundPixelsBit.mjs';
import { textureBit } from '../../../rendering/high-shader/shader-bits/textureBit.mjs';
import { Shader } from '../../../rendering/renderers/shared/shader/Shader.mjs';
import { Texture } from '../../../rendering/renderers/shared/texture/Texture.mjs';
import { warn } from '../../../utils/logging/warn.mjs';

"use strict";
class GpuMeshAdapter {
  init() {
    const gpuProgram = compileHighShaderGpuProgram({
      name: "mesh",
      bits: [
        localUniformBit,
        textureBit,
        roundPixelsBit
      ]
    });
    this._shader = new Shader({
      gpuProgram,
      resources: {
        uTexture: Texture.EMPTY._source,
        uSampler: Texture.EMPTY._source.style,
        textureUniforms: {
          uTextureMatrix: { type: "mat3x3<f32>", value: new Matrix() }
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
      warn("Mesh shader has no gpuProgram", mesh.shader);
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
    ExtensionType.WebGPUPipesAdaptor
  ],
  name: "mesh"
};

export { GpuMeshAdapter };
//# sourceMappingURL=GpuMeshAdapter.mjs.map
