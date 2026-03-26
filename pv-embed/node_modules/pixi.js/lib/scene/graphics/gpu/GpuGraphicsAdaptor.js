'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var Matrix = require('../../../maths/matrix/Matrix.js');
var getTextureBatchBindGroup = require('../../../rendering/batcher/gpu/getTextureBatchBindGroup.js');
var compileHighShaderToProgram = require('../../../rendering/high-shader/compileHighShaderToProgram.js');
var colorBit = require('../../../rendering/high-shader/shader-bits/colorBit.js');
var generateTextureBatchBit = require('../../../rendering/high-shader/shader-bits/generateTextureBatchBit.js');
var localUniformBit = require('../../../rendering/high-shader/shader-bits/localUniformBit.js');
var roundPixelsBit = require('../../../rendering/high-shader/shader-bits/roundPixelsBit.js');
var Shader = require('../../../rendering/renderers/shared/shader/Shader.js');
var UniformGroup = require('../../../rendering/renderers/shared/shader/UniformGroup.js');

"use strict";
class GpuGraphicsAdaptor {
  constructor() {
    this._maxTextures = 0;
  }
  contextChange(renderer) {
    const localUniforms = new UniformGroup.UniformGroup({
      uTransformMatrix: { value: new Matrix.Matrix(), type: "mat3x3<f32>" },
      uColor: { value: new Float32Array([1, 1, 1, 1]), type: "vec4<f32>" },
      uRound: { value: 0, type: "f32" }
    });
    this._maxTextures = renderer.limits.maxBatchableTextures;
    const gpuProgram = compileHighShaderToProgram.compileHighShaderGpuProgram({
      name: "graphics",
      bits: [
        colorBit.colorBit,
        generateTextureBatchBit.generateTextureBatchBit(this._maxTextures),
        localUniformBit.localUniformBitGroup2,
        roundPixelsBit.roundPixelsBit
      ]
    });
    this.shader = new Shader.Shader({
      gpuProgram,
      resources: {
        // added on the fly!
        localUniforms
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
    const encoder = renderer.encoder;
    encoder.setGeometry(batcher.geometry, shader.gpuProgram);
    const globalUniformsBindGroup = renderer.globalUniforms.bindGroup;
    encoder.setBindGroup(0, globalUniformsBindGroup, shader.gpuProgram);
    const localBindGroup = renderer.renderPipes.uniformBatch.getUniformBindGroup(shader.resources.localUniforms, true);
    encoder.setBindGroup(2, localBindGroup, shader.gpuProgram);
    const batches = instructions.instructions;
    let topology = null;
    for (let i = 0; i < instructions.instructionSize; i++) {
      const batch = batches[i];
      if (batch.topology !== topology) {
        topology = batch.topology;
        encoder.setPipelineFromGeometryProgramAndState(
          batcher.geometry,
          shader.gpuProgram,
          graphicsPipe.state,
          batch.topology
        );
      }
      shader.groups[1] = batch.bindGroup;
      if (!batch.gpuBindGroup) {
        const textureBatch = batch.textures;
        batch.bindGroup = getTextureBatchBindGroup.getTextureBatchBindGroup(
          textureBatch.textures,
          textureBatch.count,
          this._maxTextures
        );
        batch.gpuBindGroup = renderer.bindGroup.getBindGroup(
          batch.bindGroup,
          shader.gpuProgram,
          1
        );
      }
      encoder.setBindGroup(1, batch.bindGroup, shader.gpuProgram);
      encoder.renderPassEncoder.drawIndexed(batch.size, 1, batch.start);
    }
  }
  destroy() {
    this.shader.destroy(true);
    this.shader = null;
  }
}
/** @ignore */
GpuGraphicsAdaptor.extension = {
  type: [
    Extensions.ExtensionType.WebGPUPipesAdaptor
  ],
  name: "graphics"
};

exports.GpuGraphicsAdaptor = GpuGraphicsAdaptor;
//# sourceMappingURL=GpuGraphicsAdaptor.js.map
