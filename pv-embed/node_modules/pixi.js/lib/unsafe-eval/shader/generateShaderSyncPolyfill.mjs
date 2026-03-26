import { BufferResource } from '../../rendering/renderers/shared/buffer/BufferResource.mjs';
import { UniformGroup } from '../../rendering/renderers/shared/shader/UniformGroup.mjs';
import { TextureSource } from '../../rendering/renderers/shared/texture/sources/TextureSource.mjs';
import { TextureStyle } from '../../rendering/renderers/shared/texture/TextureStyle.mjs';

"use strict";
function generateShaderSyncPolyfill() {
  return syncShader;
}
function syncShader(renderer, shader, syncData) {
  const gl = renderer.gl;
  const shaderSystem = renderer.shader;
  const programData = shaderSystem._getProgramData(shader.glProgram);
  for (const i in shader.groups) {
    const bindGroup = shader.groups[i];
    for (const j in bindGroup.resources) {
      const resource = bindGroup.resources[j];
      if (resource instanceof UniformGroup) {
        if (resource.ubo) {
          shaderSystem.bindUniformBlock(
            resource,
            shader._uniformBindMap[i][j],
            syncData.blockIndex++
          );
        } else {
          shaderSystem.updateUniformGroup(resource);
        }
      } else if (resource instanceof BufferResource) {
        shaderSystem.bindUniformBlock(
          resource,
          shader._uniformBindMap[i][j],
          syncData.blockIndex++
        );
      } else if (resource instanceof TextureSource) {
        renderer.texture.bind(resource, syncData.textureCount);
        const uniformName = shader._uniformBindMap[i][j];
        const uniformData = programData.uniformData[uniformName];
        if (uniformData) {
          if (uniformData.value !== syncData.textureCount) {
            gl.uniform1i(uniformData.location, syncData.textureCount);
          }
          syncData.textureCount++;
        }
      } else if (resource instanceof TextureStyle) {
      }
    }
  }
}

export { generateShaderSyncPolyfill };
//# sourceMappingURL=generateShaderSyncPolyfill.mjs.map
