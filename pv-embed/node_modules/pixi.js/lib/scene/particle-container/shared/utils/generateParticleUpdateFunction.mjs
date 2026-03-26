import { getAttributeInfoFromFormat } from '../../../../rendering/renderers/shared/geometry/utils/getAttributeInfoFromFormat.mjs';

"use strict";
function generateParticleUpdateFunction(properties) {
  return {
    dynamicUpdate: generateUpdateFunction(properties, true),
    staticUpdate: generateUpdateFunction(properties, false)
  };
}
function generateUpdateFunction(properties, dynamic) {
  const funcFragments = [];
  funcFragments.push(`

        var index = 0;

        for (let i = 0; i < ps.length; ++i)
        {
            const p = ps[i];

            `);
  let offset = 0;
  for (const i in properties) {
    const property = properties[i];
    if (dynamic !== property.dynamic) continue;
    funcFragments.push(`offset = index + ${offset}`);
    funcFragments.push(property.code);
    const attributeInfo = getAttributeInfoFromFormat(property.format);
    offset += attributeInfo.stride / 4;
  }
  funcFragments.push(`
            index += stride * 4;
        }
    `);
  funcFragments.unshift(`
        var stride = ${offset};
    `);
  const functionSource = funcFragments.join("\n");
  return new Function("ps", "f32v", "u32v", functionSource);
}

export { generateParticleUpdateFunction };
//# sourceMappingURL=generateParticleUpdateFunction.mjs.map
