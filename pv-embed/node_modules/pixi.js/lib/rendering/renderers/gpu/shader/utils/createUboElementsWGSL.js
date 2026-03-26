'use strict';

"use strict";
const WGSL_ALIGN_SIZE_DATA = {
  i32: { align: 4, size: 4 },
  u32: { align: 4, size: 4 },
  f32: { align: 4, size: 4 },
  f16: { align: 2, size: 2 },
  "vec2<i32>": { align: 8, size: 8 },
  "vec2<u32>": { align: 8, size: 8 },
  "vec2<f32>": { align: 8, size: 8 },
  "vec2<f16>": { align: 4, size: 4 },
  "vec3<i32>": { align: 16, size: 12 },
  "vec3<u32>": { align: 16, size: 12 },
  "vec3<f32>": { align: 16, size: 12 },
  "vec3<f16>": { align: 8, size: 6 },
  "vec4<i32>": { align: 16, size: 16 },
  "vec4<u32>": { align: 16, size: 16 },
  "vec4<f32>": { align: 16, size: 16 },
  "vec4<f16>": { align: 8, size: 8 },
  "mat2x2<f32>": { align: 8, size: 16 },
  "mat2x2<f16>": { align: 4, size: 8 },
  "mat3x2<f32>": { align: 8, size: 24 },
  "mat3x2<f16>": { align: 4, size: 12 },
  "mat4x2<f32>": { align: 8, size: 32 },
  "mat4x2<f16>": { align: 4, size: 16 },
  "mat2x3<f32>": { align: 16, size: 32 },
  "mat2x3<f16>": { align: 8, size: 16 },
  "mat3x3<f32>": { align: 16, size: 48 },
  "mat3x3<f16>": { align: 8, size: 24 },
  "mat4x3<f32>": { align: 16, size: 64 },
  "mat4x3<f16>": { align: 8, size: 32 },
  "mat2x4<f32>": { align: 16, size: 32 },
  "mat2x4<f16>": { align: 8, size: 16 },
  "mat3x4<f32>": { align: 16, size: 48 },
  "mat3x4<f16>": { align: 8, size: 24 },
  "mat4x4<f32>": { align: 16, size: 64 },
  "mat4x4<f16>": { align: 8, size: 32 }
};
function createUboElementsWGSL(uniformData) {
  const uboElements = uniformData.map((data) => ({
    data,
    offset: 0,
    size: 0
  }));
  let offset = 0;
  for (let i = 0; i < uboElements.length; i++) {
    const uboElement = uboElements[i];
    let size = WGSL_ALIGN_SIZE_DATA[uboElement.data.type].size;
    const align = WGSL_ALIGN_SIZE_DATA[uboElement.data.type].align;
    if (!WGSL_ALIGN_SIZE_DATA[uboElement.data.type]) {
      throw new Error(`[Pixi.js] WebGPU UniformBuffer: Unknown type ${uboElement.data.type}`);
    }
    if (uboElement.data.size > 1) {
      size = Math.max(size, align) * uboElement.data.size;
    }
    offset = Math.ceil(offset / align) * align;
    uboElement.size = size;
    uboElement.offset = offset;
    offset += size;
  }
  offset = Math.ceil(offset / 16) * 16;
  return { uboElements, size: offset };
}

exports.WGSL_ALIGN_SIZE_DATA = WGSL_ALIGN_SIZE_DATA;
exports.createUboElementsWGSL = createUboElementsWGSL;
//# sourceMappingURL=createUboElementsWGSL.js.map
