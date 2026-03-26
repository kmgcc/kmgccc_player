import { getAttributeInfoFromFormat } from '../../rendering/renderers/shared/geometry/utils/getAttributeInfoFromFormat.mjs';
import { particleUpdateFunctions } from './particleUpdateFunctions.mjs';

"use strict";
function generateParticleUpdatePolyfill(properties) {
  const allProperties = Object.values(properties);
  const dynamicProperties = allProperties.filter((p) => p.dynamic);
  const staticProperties = allProperties.filter((p) => !p.dynamic);
  return {
    dynamicUpdate: generateUpdateFunction(dynamicProperties),
    staticUpdate: generateUpdateFunction(staticProperties)
  };
}
function generateUpdateFunction(properties) {
  let stride = 0;
  const updateData = [];
  for (let i = 0; i < properties.length; i++) {
    const property = properties[i];
    const attributeStride = getAttributeInfoFromFormat(property.format).stride / 4;
    stride += attributeStride;
    updateData.push({
      stride: attributeStride,
      updateFunction: property.updateFunction || particleUpdateFunctions[property.attributeName]
    });
  }
  return (ps, f32v, u32v) => {
    let offset = 0;
    for (let i = 0; i < updateData.length; i++) {
      const obx = updateData[i];
      obx.updateFunction(ps, f32v, u32v, offset, stride);
      offset += obx.stride;
    }
  };
}

export { generateParticleUpdatePolyfill };
//# sourceMappingURL=generateParticleUpdatePolyfill.mjs.map
