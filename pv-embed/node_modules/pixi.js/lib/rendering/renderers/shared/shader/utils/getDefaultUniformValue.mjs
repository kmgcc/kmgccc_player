"use strict";
function getDefaultUniformValue(type, size) {
  switch (type) {
    case "f32":
      return 0;
    case "vec2<f32>":
      return new Float32Array(2 * size);
    case "vec3<f32>":
      return new Float32Array(3 * size);
    case "vec4<f32>":
      return new Float32Array(4 * size);
    case "mat2x2<f32>":
      return new Float32Array([
        1,
        0,
        0,
        1
      ]);
    case "mat3x3<f32>":
      return new Float32Array([
        1,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        1
      ]);
    case "mat4x4<f32>":
      return new Float32Array([
        1,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        1
      ]);
  }
  return null;
}

export { getDefaultUniformValue };
//# sourceMappingURL=getDefaultUniformValue.mjs.map
