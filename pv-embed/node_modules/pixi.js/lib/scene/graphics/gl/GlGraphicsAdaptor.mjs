import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { Matrix } from '../../../maths/matrix/Matrix.mjs';
import { compileHighShaderGlProgram } from '../../../rendering/high-shader/compileHighShaderToProgram.mjs';
import { colorBitGl } from '../../../rendering/high-shader/shader-bits/colorBit.mjs';
import { generateTextureBatchBitGl } from '../../../rendering/high-shader/shader-bits/generateTextureBatchBit.mjs';
import { localUniformBitGl } from '../../../rendering/high-shader/shader-bits/localUniformBit.mjs';
import { roundPixelsBitGl } from '../../../rendering/high-shader/shader-bits/roundPixelsBit.mjs';
import { getBatchSamplersUniformGroup } from '../../../rendering/renderers/gl/shader/getBatchSamplersUniformGroup.mjs';
import { Shader } from '../../../rendering/renderers/shared/shader/Shader.mjs';
import { UniformGroup } from '../../../rendering/renderers/shared/shader/UniformGroup.mjs';

"use strict";
class GlGraphicsAdaptor {
  contextChange(renderer) {
    const uniforms = new UniformGroup({
      uColor: { value: new Float32Array([1, 1, 1, 1]), type: "vec4<f32>" },
      uTransformMatrix: { value: new Matrix(), type: "mat3x3<f32>" },
      uRound: { value: 0, type: "f32" }
    });
    const maxTextures = renderer.limits.maxBatchableTextures;
    const glProgram = compileHighShaderGlProgram({
      name: "graphics",
      bits: [
        colorBitGl,
        generateTextureBatchBitGl(maxTextures),
        localUniformBitGl,
        roundPixelsBitGl
      ]
    });
    this.shader = new Shader({
      glProgram,
      resources: {
        localUniforms: uniforms,
        batchSamplers: getBatchSamplersUniformGroup(maxTextures)
      }
    });
  }
  execute(graphicsPipe, renderable) {
    const context = renderable.context;
    const shader = context.customShader || this.shader;
    const renderer = graphicsPipe.renderer;
    const contextSystem = renderer.graphicsContext;
    const {
      batcher,
      instructions
    } = contextSystem.getContextRenderData(context);
    shader.groups[0] = renderer.globalUniforms.bindGroup;
    renderer.state.set(graphicsPipe.state);
    renderer.shader.bind(shader);
    renderer.geometry.bind(batcher.geometry, shader.glProgram);
    const batches = instructions.instructions;
    for (let i = 0; i < instructions.instructionSize; i++) {
      const batch = batches[i];
      if (batch.size) {
        for (let j = 0; j < batch.textures.count; j++) {
          renderer.texture.bind(batch.textures.textures[j], j);
        }
        renderer.geometry.draw(batch.topology, batch.size, batch.start);
      }
    }
  }
  destroy() {
    this.shader.destroy(true);
    this.shader = null;
  }
}
/** @ignore */
GlGraphicsAdaptor.extension = {
  type: [
    ExtensionType.WebGLPipesAdaptor
  ],
  name: "graphics"
};

export { GlGraphicsAdaptor };
//# sourceMappingURL=GlGraphicsAdaptor.mjs.map
