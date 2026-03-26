import { WGSL_TO_STD40_SIZE } from './createUboElementsSTD40.mjs';

"use strict";
function generateArraySyncSTD40(uboElement, offsetToAdd) {
  const rowSize = Math.max(WGSL_TO_STD40_SIZE[uboElement.data.type] / 16, 1);
  const elementSize = uboElement.data.value.length / uboElement.data.size;
  const remainder = (4 - elementSize % 4) % 4;
  const data = uboElement.data.type.indexOf("i32") >= 0 ? "dataInt32" : "data";
  return `
        v = uv.${uboElement.data.name};
        offset += ${offsetToAdd};

        arrayOffset = offset;

        t = 0;

        for(var i=0; i < ${uboElement.data.size * rowSize}; i++)
        {
            for(var j = 0; j < ${elementSize}; j++)
            {
                ${data}[arrayOffset++] = v[t++];
            }
            ${remainder !== 0 ? `arrayOffset += ${remainder};` : ""}
        }
    `;
}

export { generateArraySyncSTD40 };
//# sourceMappingURL=generateArraySyncSTD40.mjs.map
