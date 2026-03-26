'use strict';

"use strict";
const UNIFORM_TYPES_VALUES = [
  "f32",
  "i32",
  "vec2<f32>",
  "vec3<f32>",
  "vec4<f32>",
  "mat2x2<f32>",
  "mat3x3<f32>",
  "mat4x4<f32>",
  "mat3x2<f32>",
  "mat4x2<f32>",
  "mat2x3<f32>",
  "mat4x3<f32>",
  "mat2x4<f32>",
  "mat3x4<f32>",
  "vec2<i32>",
  "vec3<i32>",
  "vec4<i32>"
];
const UNIFORM_TYPES_MAP = UNIFORM_TYPES_VALUES.reduce((acc, type) => {
  acc[type] = true;
  return acc;
}, {});

exports.UNIFORM_TYPES_MAP = UNIFORM_TYPES_MAP;
exports.UNIFORM_TYPES_VALUES = UNIFORM_TYPES_VALUES;
//# sourceMappingURL=types.js.map
