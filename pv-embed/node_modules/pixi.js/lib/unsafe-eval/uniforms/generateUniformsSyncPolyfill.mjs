import { uniformParsers } from '../../rendering/renderers/shared/shader/utils/uniformParsers.mjs';
import { uniformParserFunctions, uniformSingleParserFunctions, uniformArrayParserFunctions } from './uniformSyncFunctions.mjs';

"use strict";
function generateUniformsSyncPolyfill(group, uniformData) {
  const functionMap = {};
  for (const i in group.uniformStructures) {
    if (!uniformData[i]) continue;
    const uniform = group.uniformStructures[i];
    let parsed = false;
    for (let j = 0; j < uniformParsers.length; j++) {
      const parser = uniformParsers[j];
      if (uniform.type === parser.type && parser.test(uniform)) {
        functionMap[i] = uniformParserFunctions[j];
        parsed = true;
        break;
      }
    }
    if (!parsed) {
      const templateType = uniform.size === 1 ? uniformSingleParserFunctions : uniformArrayParserFunctions;
      functionMap[i] = templateType[uniform.type];
    }
  }
  return (ud, uv, renderer) => {
    const gl = renderer.gl;
    for (const i in functionMap) {
      const v = uv[i];
      const cu = ud[i];
      const cv = ud[i].value;
      functionMap[i](i, cu, cv, v, ud, uv, gl);
    }
  };
}

export { generateUniformsSyncPolyfill };
//# sourceMappingURL=generateUniformsSyncPolyfill.mjs.map
