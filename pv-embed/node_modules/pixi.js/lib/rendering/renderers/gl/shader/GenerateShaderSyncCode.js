'use strict';

var BufferResource = require('../../shared/buffer/BufferResource.js');
var UniformGroup = require('../../shared/shader/UniformGroup.js');
var TextureSource = require('../../shared/texture/sources/TextureSource.js');

"use strict";
function generateShaderSyncCode(shader, shaderSystem) {
  const funcFragments = [];
  const headerFragments = [`
        var g = s.groups;
        var sS = r.shader;
        var p = s.glProgram;
        var ugS = r.uniformGroup;
        var resources;
    `];
  let addedTextreSystem = false;
  let textureCount = 0;
  const programData = shaderSystem._getProgramData(shader.glProgram);
  for (const i in shader.groups) {
    const group = shader.groups[i];
    funcFragments.push(`
            resources = g[${i}].resources;
        `);
    for (const j in group.resources) {
      const resource = group.resources[j];
      if (resource instanceof UniformGroup.UniformGroup) {
        if (resource.ubo) {
          const resName = shader._uniformBindMap[i][Number(j)];
          funcFragments.push(`
                        sS.bindUniformBlock(
                            resources[${j}],
                            '${resName}',
                            ${shader.glProgram._uniformBlockData[resName].index}
                        );
                    `);
        } else {
          funcFragments.push(`
                        ugS.updateUniformGroup(resources[${j}], p, sD);
                    `);
        }
      } else if (resource instanceof BufferResource.BufferResource) {
        const resName = shader._uniformBindMap[i][Number(j)];
        funcFragments.push(`
                    sS.bindUniformBlock(
                        resources[${j}],
                        '${resName}',
                        ${shader.glProgram._uniformBlockData[resName].index}
                    );
                `);
      } else if (resource instanceof TextureSource.TextureSource) {
        const uniformName = shader._uniformBindMap[i][j];
        const uniformData = programData.uniformData[uniformName];
        if (uniformData) {
          if (!addedTextreSystem) {
            addedTextreSystem = true;
            headerFragments.push(`
                        var tS = r.texture;
                        `);
          }
          shaderSystem._gl.uniform1i(uniformData.location, textureCount);
          funcFragments.push(`
                        tS.bind(resources[${j}], ${textureCount});
                    `);
          textureCount++;
        }
      }
    }
  }
  const functionSource = [...headerFragments, ...funcFragments].join("\n");
  return new Function("r", "s", "sD", functionSource);
}

exports.generateShaderSyncCode = generateShaderSyncCode;
//# sourceMappingURL=GenerateShaderSyncCode.js.map
