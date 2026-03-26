import { getAttributeInfoFromFormat } from '../../../shared/geometry/utils/getAttributeInfoFromFormat.mjs';
import { mapGlToVertexFormat } from './mapType.mjs';

"use strict";
function extractAttributesFromGlProgram(program, gl, sortAttributes = false) {
  const attributes = {};
  const totalAttributes = gl.getProgramParameter(program, gl.ACTIVE_ATTRIBUTES);
  for (let i = 0; i < totalAttributes; i++) {
    const attribData = gl.getActiveAttrib(program, i);
    if (attribData.name.startsWith("gl_")) {
      continue;
    }
    const format = mapGlToVertexFormat(gl, attribData.type);
    attributes[attribData.name] = {
      location: 0,
      // set further down..
      format,
      stride: getAttributeInfoFromFormat(format).stride,
      offset: 0,
      instance: false,
      start: 0
    };
  }
  const keys = Object.keys(attributes);
  if (sortAttributes) {
    keys.sort((a, b) => a > b ? 1 : -1);
    for (let i = 0; i < keys.length; i++) {
      attributes[keys[i]].location = i;
      gl.bindAttribLocation(program, i, keys[i]);
    }
    gl.linkProgram(program);
  } else {
    for (let i = 0; i < keys.length; i++) {
      attributes[keys[i]].location = gl.getAttribLocation(program, keys[i]);
    }
  }
  return attributes;
}

export { extractAttributesFromGlProgram };
//# sourceMappingURL=extractAttributesFromGlProgram.mjs.map
