'use strict';

"use strict";
const uboParserFunctions = [
  (name, data, offset, uv, _v) => {
    const matrix = uv[name].toArray(true);
    data[offset] = matrix[0];
    data[offset + 1] = matrix[1];
    data[offset + 2] = matrix[2];
    data[offset + 4] = matrix[3];
    data[offset + 5] = matrix[4];
    data[offset + 6] = matrix[5];
    data[offset + 8] = matrix[6];
    data[offset + 9] = matrix[7];
    data[offset + 10] = matrix[8];
  },
  (name, data, offset, uv, v) => {
    v = uv[name];
    data[offset] = v.x;
    data[offset + 1] = v.y;
    data[offset + 2] = v.width;
    data[offset + 3] = v.height;
  },
  (name, data, offset, uv, v) => {
    v = uv[name];
    data[offset] = v.x;
    data[offset + 1] = v.y;
  },
  (name, data, offset, uv, v) => {
    v = uv[name];
    data[offset] = v.red;
    data[offset + 1] = v.green;
    data[offset + 2] = v.blue;
    data[offset + 3] = v.alpha;
  },
  (name, data, offset, uv, v) => {
    v = uv[name];
    data[offset] = v.red;
    data[offset + 1] = v.green;
    data[offset + 2] = v.blue;
  }
];
const uboSingleFunctionsWGSL = {
  f32: (_name, data, offset, _uv, v) => {
    data[offset] = v;
  },
  i32: (_name, data, offset, _uv, v) => {
    data[offset] = v;
  },
  "vec2<f32>": (_name, data, offset, _uv, v) => {
    data[offset] = v[0];
    data[offset + 1] = v[1];
  },
  "vec3<f32>": (_name, data, offset, _uv, v) => {
    data[offset] = v[0];
    data[offset + 1] = v[1];
    data[offset + 2] = v[2];
  },
  "vec4<f32>": (_name, data, offset, _uv, v) => {
    data[offset] = v[0];
    data[offset + 1] = v[1];
    data[offset + 2] = v[2];
    data[offset + 3] = v[3];
  },
  "mat2x2<f32>": (_name, data, offset, _uv, v) => {
    data[offset] = v[0];
    data[offset + 1] = v[1];
    data[offset + 2] = v[2];
    data[offset + 3] = v[3];
  },
  "mat3x3<f32>": (_name, data, offset, _uv, v) => {
    data[offset] = v[0];
    data[offset + 1] = v[1];
    data[offset + 2] = v[2];
    data[offset + 4] = v[3];
    data[offset + 5] = v[4];
    data[offset + 6] = v[5];
    data[offset + 8] = v[6];
    data[offset + 9] = v[7];
    data[offset + 10] = v[8];
  },
  "mat4x4<f32>": (_name, data, offset, _uv, v) => {
    for (let i = 0; i < 16; i++) {
      data[offset + i] = v[i];
    }
  },
  "mat3x2<f32>": (_name, data, offset, _uv, v) => {
    for (let i = 0; i < 6; i++) {
      data[offset + (i / 3 | 0) * 4 + i % 3] = v[i];
    }
  },
  "mat4x2<f32>": (_name, data, offset, _uv, v) => {
    for (let i = 0; i < 8; i++) {
      data[offset + (i / 4 | 0) * 4 + i % 4] = v[i];
    }
  },
  "mat2x3<f32>": (_name, data, offset, _uv, v) => {
    for (let i = 0; i < 6; i++) {
      data[offset + (i / 2 | 0) * 4 + i % 2] = v[i];
    }
  },
  "mat4x3<f32>": (_name, data, offset, _uv, v) => {
    for (let i = 0; i < 12; i++) {
      data[offset + (i / 4 | 0) * 4 + i % 4] = v[i];
    }
  },
  "mat2x4<f32>": (_name, data, offset, _uv, v) => {
    for (let i = 0; i < 8; i++) {
      data[offset + (i / 2 | 0) * 4 + i % 2] = v[i];
    }
  },
  "mat3x4<f32>": (_name, data, offset, _uv, v) => {
    for (let i = 0; i < 12; i++) {
      data[offset + (i / 3 | 0) * 4 + i % 3] = v[i];
    }
  }
};
const uboSingleFunctionsSTD40 = {
  f32: (_name, data, offset, _uv, v) => {
    data[offset] = v;
  },
  i32: (_name, data, offset, _uv, v) => {
    data[offset] = v;
  },
  "vec2<f32>": (_name, data, offset, _uv, v) => {
    data[offset] = v[0];
    data[offset + 1] = v[1];
  },
  "vec3<f32>": (_name, data, offset, _uv, v) => {
    data[offset] = v[0];
    data[offset + 1] = v[1];
    data[offset + 2] = v[2];
  },
  "vec4<f32>": (_name, data, offset, _uv, v) => {
    data[offset] = v[0];
    data[offset + 1] = v[1];
    data[offset + 2] = v[2];
    data[offset + 3] = v[3];
  },
  "mat2x2<f32>": (_name, data, offset, _uv, v) => {
    data[offset] = v[0];
    data[offset + 1] = v[1];
    data[offset + 4] = v[2];
    data[offset + 5] = v[3];
  },
  "mat3x3<f32>": (_name, data, offset, _uv, v) => {
    data[offset] = v[0];
    data[offset + 1] = v[1];
    data[offset + 2] = v[2];
    data[offset + 4] = v[3];
    data[offset + 5] = v[4];
    data[offset + 6] = v[5];
    data[offset + 8] = v[6];
    data[offset + 9] = v[7];
    data[offset + 10] = v[8];
  },
  "mat4x4<f32>": (_name, data, offset, _uv, v) => {
    for (let i = 0; i < 16; i++) {
      data[offset + i] = v[i];
    }
  },
  "mat3x2<f32>": (_name, data, offset, _uv, v) => {
    for (let i = 0; i < 6; i++) {
      data[offset + (i / 3 | 0) * 4 + i % 3] = v[i];
    }
  },
  "mat4x2<f32>": (_name, data, offset, _uv, v) => {
    for (let i = 0; i < 8; i++) {
      data[offset + (i / 4 | 0) * 4 + i % 4] = v[i];
    }
  },
  "mat2x3<f32>": (_name, data, offset, _uv, v) => {
    for (let i = 0; i < 6; i++) {
      data[offset + (i / 2 | 0) * 4 + i % 2] = v[i];
    }
  },
  "mat4x3<f32>": (_name, data, offset, _uv, v) => {
    for (let i = 0; i < 12; i++) {
      data[offset + (i / 4 | 0) * 4 + i % 4] = v[i];
    }
  },
  "mat2x4<f32>": (_name, data, offset, _uv, v) => {
    for (let i = 0; i < 8; i++) {
      data[offset + (i / 2 | 0) * 4 + i % 2] = v[i];
    }
  },
  "mat3x4<f32>": (_name, data, offset, _uv, v) => {
    for (let i = 0; i < 12; i++) {
      data[offset + (i / 3 | 0) * 4 + i % 3] = v[i];
    }
  }
};

exports.uboParserFunctions = uboParserFunctions;
exports.uboSingleFunctionsSTD40 = uboSingleFunctionsSTD40;
exports.uboSingleFunctionsWGSL = uboSingleFunctionsWGSL;
//# sourceMappingURL=uboSyncFunctions.js.map
