import { BufferResource } from '../../../shared/buffer/BufferResource.mjs';
import { UniformGroup } from '../../../shared/shader/UniformGroup.mjs';
import { uniformParsers } from '../../../shared/shader/utils/uniformParsers.mjs';
import { UNIFORM_TO_SINGLE_SETTERS, UNIFORM_TO_ARRAY_SETTERS } from './generateUniformsSyncTypes.mjs';

"use strict";
function generateUniformsSync(group, uniformData) {
  const funcFragments = [`
        var v = null;
        var cv = null;
        var cu = null;
        var t = 0;
        var gl = renderer.gl;
        var name = null;
    `];
  for (const i in group.uniforms) {
    if (!uniformData[i]) {
      if (group.uniforms[i] instanceof UniformGroup) {
        if (group.uniforms[i].ubo) {
          funcFragments.push(`
                        renderer.shader.bindUniformBlock(uv.${i}, "${i}");
                    `);
        } else {
          funcFragments.push(`
                        renderer.shader.updateUniformGroup(uv.${i});
                    `);
        }
      } else if (group.uniforms[i] instanceof BufferResource) {
        funcFragments.push(`
                        renderer.shader.bindBufferResource(uv.${i}, "${i}");
                    `);
      }
      continue;
    }
    const uniform = group.uniformStructures[i];
    let parsed = false;
    for (let j = 0; j < uniformParsers.length; j++) {
      const parser = uniformParsers[j];
      if (uniform.type === parser.type && parser.test(uniform)) {
        funcFragments.push(`name = "${i}";`, uniformParsers[j].uniform);
        parsed = true;
        break;
      }
    }
    if (!parsed) {
      const templateType = uniform.size === 1 ? UNIFORM_TO_SINGLE_SETTERS : UNIFORM_TO_ARRAY_SETTERS;
      const template = templateType[uniform.type].replace("location", `ud["${i}"].location`);
      funcFragments.push(`
            cu = ud["${i}"];
            cv = cu.value;
            v = uv["${i}"];
            ${template};`);
    }
  }
  return new Function("ud", "uv", "renderer", "syncData", funcFragments.join("\n"));
}

export { generateUniformsSync };
//# sourceMappingURL=generateUniformsSync.mjs.map
