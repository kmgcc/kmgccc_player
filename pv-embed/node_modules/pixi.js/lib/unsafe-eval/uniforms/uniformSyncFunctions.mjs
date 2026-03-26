"use strict";
const uniformSingleParserFunctions = {
  f32(name, cu, cv, v, ud, _uv, gl) {
    if (cv !== v) {
      cu.value = v;
      gl.uniform1f(ud[name].location, v);
    }
  },
  "vec2<f32>"(name, _cu, cv, v, ud, _uv, gl) {
    if (cv[0] !== v[0] || cv[1] !== v[1]) {
      cv[0] = v[0];
      cv[1] = v[1];
      gl.uniform2f(ud[name].location, v[0], v[1]);
    }
  },
  "vec3<f32>"(name, _cu, cv, v, ud, _uv, gl) {
    if (cv[0] !== v[0] || cv[1] !== v[1] || cv[2] !== v[2]) {
      cv[0] = v[0];
      cv[1] = v[1];
      cv[2] = v[2];
      gl.uniform3f(ud[name].location, v[0], v[1], v[2]);
    }
  },
  "vec4<f32>"(name, _cu, cv, v, ud, _uv, gl) {
    if (cv[0] !== v[0] || cv[1] !== v[1] || cv[2] !== v[2] || cv[3] !== v[3]) {
      cv[0] = v[0];
      cv[1] = v[1];
      cv[2] = v[2];
      cv[3] = v[3];
      gl.uniform4f(ud[name].location, v[0], v[1], v[2], v[3]);
    }
  },
  i32(name, cu, cv, v, ud, _uv, gl) {
    if (cv !== v) {
      cu.value = v;
      gl.uniform1i(ud[name].location, v);
    }
  },
  "vec2<i32>"(name, _cu, cv, v, ud, _uv, gl) {
    if (cv[0] !== v[0] || cv[1] !== v[1]) {
      cv[0] = v[0];
      cv[1] = v[1];
      gl.uniform2i(ud[name].location, v[0], v[1]);
    }
  },
  "vec3<i32>"(name, _cu, cv, v, ud, _uv, gl) {
    if (cv[0] !== v[0] || cv[1] !== v[1] || cv[2] !== v[2]) {
      cv[0] = v[0];
      cv[1] = v[1];
      cv[2] = v[2];
      gl.uniform3i(ud[name].location, v[0], v[1], v[2]);
    }
  },
  "vec4<i32>"(name, _cu, cv, v, ud, _uv, gl) {
    if (cv[0] !== v[0] || cv[1] !== v[1] || cv[2] !== v[2] || cv[3] !== v[3]) {
      cv[0] = v[0];
      cv[1] = v[1];
      cv[2] = v[2];
      cv[3] = v[3];
      gl.uniform4i(ud[name].location, v[0], v[1], v[2], v[3]);
    }
  },
  u32(name, cu, cv, v, ud, _uv, gl) {
    if (cv !== v) {
      cu.value = v;
      gl.uniform1ui(ud[name].location, v);
    }
  },
  "vec2<u32>"(name, _cu, cv, v, ud, _uv, gl) {
    if (cv[0] !== v[0] || cv[1] !== v[1]) {
      cv[0] = v[0];
      cv[1] = v[1];
      gl.uniform2ui(ud[name].location, v[0], v[1]);
    }
  },
  "vec3<u32>"(name, _cu, cv, v, ud, _uv, gl) {
    if (cv[0] !== v[0] || cv[1] !== v[1] || cv[2] !== v[2]) {
      cv[0] = v[0];
      cv[1] = v[1];
      cv[2] = v[2];
      gl.uniform3ui(ud[name].location, v[0], v[1], v[2]);
    }
  },
  "vec4<u32>"(name, _cu, cv, v, ud, _uv, gl) {
    if (cv[0] !== v[0] || cv[1] !== v[1] || cv[2] !== v[2] || cv[3] !== v[3]) {
      cv[0] = v[0];
      cv[1] = v[1];
      cv[2] = v[2];
      cv[3] = v[3];
      gl.uniform4ui(ud[name].location, v[0], v[1], v[2], v[3]);
    }
  },
  bool(name, cu, cv, v, ud, _uv, gl) {
    if (cv !== v) {
      cu.value = v;
      gl.uniform1i(ud[name].location, v);
    }
  },
  "vec2<bool>"(name, _cu, cv, v, ud, _uv, gl) {
    if (cv[0] !== v[0] || cv[1] !== v[1]) {
      cv[0] = v[0];
      cv[1] = v[1];
      gl.uniform2i(ud[name].location, v[0], v[1]);
    }
  },
  "vec3<bool>"(name, _cu, cv, v, ud, _uv, gl) {
    if (cv[0] !== v[0] || cv[1] !== v[1] || cv[2] !== v[2]) {
      cv[0] = v[0];
      cv[1] = v[1];
      cv[2] = v[2];
      gl.uniform3i(ud[name].location, v[0], v[1], v[2]);
    }
  },
  "vec4<bool>"(name, _cu, cv, v, ud, _uv, gl) {
    if (cv[0] !== v[0] || cv[1] !== v[1] || cv[2] !== v[2] || cv[3] !== v[3]) {
      cv[0] = v[0];
      cv[1] = v[1];
      cv[2] = v[2];
      cv[3] = v[3];
      gl.uniform4i(ud[name].location, v[0], v[1], v[2], v[3]);
    }
  },
  "mat2x2<f32>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniformMatrix2fv(ud[name].location, false, v);
  },
  "mat3x3<f32>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniformMatrix3fv(ud[name].location, false, v);
  },
  "mat4x4<f32>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniformMatrix4fv(ud[name].location, false, v);
  }
};
const uniformArrayParserFunctions = {
  f32(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniform1fv(ud[name].location, v);
  },
  "vec2<f32>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniform2fv(ud[name].location, v);
  },
  "vec3<f32>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniform3fv(ud[name].location, v);
  },
  "vec4<f32>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniform4fv(ud[name].location, v);
  },
  "mat2x2<f32>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniformMatrix2fv(ud[name].location, false, v);
  },
  "mat3x3<f32>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniformMatrix3fv(ud[name].location, false, v);
  },
  "mat4x4<f32>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniformMatrix4fv(ud[name].location, false, v);
  },
  i32(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniform1iv(ud[name].location, v);
  },
  "vec2<i32>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniform2iv(ud[name].location, v);
  },
  "vec3<i32>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniform3iv(ud[name].location, v);
  },
  "vec4<i32>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniform4iv(ud[name].location, v);
  },
  u32(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniform1iv(ud[name].location, v);
  },
  "vec2<u32>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniform2iv(ud[name].location, v);
  },
  "vec3<u32>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniform3iv(ud[name].location, v);
  },
  "vec4<u32>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniform4iv(ud[name].location, v);
  },
  bool(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniform1iv(ud[name].location, v);
  },
  "vec2<bool>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniform2iv(ud[name].location, v);
  },
  "vec3<bool>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniform3iv(ud[name].location, v);
  },
  "vec4<bool>"(name, _cu, _cv, v, ud, _uv, gl) {
    gl.uniform4iv(ud[name].location, v);
  }
};
const uniformParserFunctions = [
  (name, _cu, _cv, _v, ud, uv, gl) => {
    gl.uniformMatrix3fv(ud[name].location, false, uv[name].toArray(true));
  },
  (name, _cu, cv, v, ud, uv, gl) => {
    cv = ud[name].value;
    v = uv[name];
    if (cv[0] !== v.x || cv[1] !== v.y || cv[2] !== v.width || cv[3] !== v.height) {
      cv[0] = v.x;
      cv[1] = v.y;
      cv[2] = v.width;
      cv[3] = v.height;
      gl.uniform4f(ud[name].location, v.x, v.y, v.width, v.height);
    }
  },
  (name, _cu, cv, v, ud, uv, gl) => {
    cv = ud[name].value;
    v = uv[name];
    if (cv[0] !== v.x || cv[1] !== v.y) {
      cv[0] = v.x;
      cv[1] = v.y;
      gl.uniform2f(ud[name].location, v.x, v.y);
    }
  },
  (name, _cu, cv, v, ud, uv, gl) => {
    cv = ud[name].value;
    v = uv[name];
    if (cv[0] !== v.red || cv[1] !== v.green || cv[2] !== v.blue || cv[3] !== v.alpha) {
      cv[0] = v.red;
      cv[1] = v.green;
      cv[2] = v.blue;
      cv[3] = v.alpha;
      gl.uniform4f(ud[name].location, v.red, v.green, v.blue, v.alpha);
    }
  },
  (name, _cu, cv, v, ud, uv, gl) => {
    cv = ud[name].value;
    v = uv[name];
    if (cv[0] !== v.red || cv[1] !== v.green || cv[2] !== v.blue) {
      cv[0] = v.red;
      cv[1] = v.green;
      cv[2] = v.blue;
      gl.uniform3f(ud[name].location, v.red, v.green, v.blue);
    }
  }
];

export { uniformArrayParserFunctions, uniformParserFunctions, uniformSingleParserFunctions };
//# sourceMappingURL=uniformSyncFunctions.mjs.map
