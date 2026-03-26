"use strict";
const particleUpdateFunctions = {
  aVertex: (ps, f32v, _u32v, offset, stride) => {
    let w0 = 0;
    let w1 = 0;
    let h0 = 0;
    let h1 = 0;
    for (let i = 0; i < ps.length; ++i) {
      const p = ps[i];
      const texture = p.texture;
      const sx = p.scaleX;
      const sy = p.scaleY;
      const ax = p.anchorX;
      const ay = p.anchorY;
      const trim = texture.trim;
      const orig = texture.orig;
      if (trim) {
        w1 = trim.x - ax * orig.width;
        w0 = w1 + trim.width;
        h1 = trim.y - ay * orig.height;
        h0 = h1 + trim.height;
      } else {
        w0 = orig.width * (1 - ax);
        w1 = orig.width * -ax;
        h0 = orig.height * (1 - ay);
        h1 = orig.height * -ay;
      }
      f32v[offset] = w1 * sx;
      f32v[offset + 1] = h1 * sy;
      f32v[offset + stride] = w0 * sx;
      f32v[offset + stride + 1] = h1 * sy;
      f32v[offset + stride * 2] = w0 * sx;
      f32v[offset + stride * 2 + 1] = h0 * sy;
      f32v[offset + stride * 3] = w1 * sx;
      f32v[offset + stride * 3 + 1] = h0 * sy;
      offset += stride * 4;
    }
  },
  aPosition: (ps, f32v, _u32v, offset, stride) => {
    for (let i = 0; i < ps.length; ++i) {
      const p = ps[i];
      const x = p.x;
      const y = p.y;
      f32v[offset] = x;
      f32v[offset + 1] = y;
      f32v[offset + stride] = x;
      f32v[offset + stride + 1] = y;
      f32v[offset + stride * 2] = x;
      f32v[offset + stride * 2 + 1] = y;
      f32v[offset + stride * 3] = x;
      f32v[offset + stride * 3 + 1] = y;
      offset += stride * 4;
    }
  },
  aRotation: (ps, f32v, _u32v, offset, stride) => {
    for (let i = 0; i < ps.length; ++i) {
      const rotation = ps[i].rotation;
      f32v[offset] = rotation;
      f32v[offset + stride] = rotation;
      f32v[offset + stride * 2] = rotation;
      f32v[offset + stride * 3] = rotation;
      offset += stride * 4;
    }
  },
  aUV: (ps, f32v, _u32v, offset, stride) => {
    for (let i = 0; i < ps.length; ++i) {
      const uvs = ps[i].texture.uvs;
      f32v[offset] = uvs.x0;
      f32v[offset + 1] = uvs.y0;
      f32v[offset + stride] = uvs.x1;
      f32v[offset + stride + 1] = uvs.y1;
      f32v[offset + stride * 2] = uvs.x2;
      f32v[offset + stride * 2 + 1] = uvs.y2;
      f32v[offset + stride * 3] = uvs.x3;
      f32v[offset + stride * 3 + 1] = uvs.y3;
      offset += stride * 4;
    }
  },
  aColor: (ps, _f32v, u32v, offset, stride) => {
    for (let i = 0; i < ps.length; ++i) {
      const c = ps[i].color;
      u32v[offset] = c;
      u32v[offset + stride] = c;
      u32v[offset + stride * 2] = c;
      u32v[offset + stride * 3] = c;
      offset += stride * 4;
    }
  }
};

export { particleUpdateFunctions };
//# sourceMappingURL=particleUpdateFunctions.mjs.map
