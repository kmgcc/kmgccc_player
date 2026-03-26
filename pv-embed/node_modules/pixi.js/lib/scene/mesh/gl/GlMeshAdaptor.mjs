import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { Matrix } from '../../../maths/matrix/Matrix.mjs';
import { compileHighShaderGlProgram } from '../../../rendering/high-shader/compileHighShaderToProgram.mjs';
import { localUniformBitGl } from '../../../rendering/high-shader/shader-bits/localUniformBit.mjs';
import { roundPixelsBitGl } from '../../../rendering/high-shader/shader-bits/roundPixelsBit.mjs';
import { textureBitGl } from '../../../rendering/high-shader/shader-bits/textureBit.mjs';
import { Shader } from '../../../rendering/renderers/shared/shader/Shader.mjs';
import { Texture } from '../../../rendering/renderers/shared/texture/Texture.mjs';
import { warn } from '../../../utils/logging/warn.mjs';

"use strict";
class GlMeshAdaptor {
  init() {
    const glProgram = compileHighShaderGlProgram({
      name: "mesh",
      bits: [
        localUniformBitGl,
        textureBitGl,
        roundPixelsBitGl
      ]
    });
    this._shader = new Shader({
      glProgram,
      resources: {
        uTexture: Texture.EMPTY.source,
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
      const texture = mesh.texture;
      const source = texture.source;
      shader.resources.uTexture = source;
      shader.resources.uSampler = source.style;
      shader.resources.textureUniforms.uniforms.uTextureMatrix = texture.textureMatrix.mapCoord;
    } else if (!shader.glProgram) {
      warn("Mesh shader has no glProgram", mesh.shader);
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
    ExtensionType.WebGLPipesAdaptor
  ],
  name: "mesh"
};

export { GlMeshAdaptor };
//# sourceMappingURL=GlMeshAdaptor.mjs.map
