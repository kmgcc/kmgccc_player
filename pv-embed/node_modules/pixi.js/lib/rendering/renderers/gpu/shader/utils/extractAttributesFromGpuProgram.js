'use strict';

var getAttributeInfoFromFormat = require('../../../shared/geometry/utils/getAttributeInfoFromFormat.js');

"use strict";
const WGSL_TO_VERTEX_TYPES = {
  f32: "float32",
  "vec2<f32>": "float32x2",
  "vec3<f32>": "float32x3",
  "vec4<f32>": "float32x4",
  vec2f: "float32x2",
  vec3f: "float32x3",
  vec4f: "float32x4",
  i32: "sint32",
  "vec2<i32>": "sint32x2",
  "vec3<i32>": "sint32x3",
  "vec4<i32>": "sint32x4",
  vec2i: "sint32x2",
  vec3i: "sint32x3",
  vec4i: "sint32x4",
  u32: "uint32",
  "vec2<u32>": "uint32x2",
  "vec3<u32>": "uint32x3",
  "vec4<u32>": "uint32x4",
  vec2u: "uint32x2",
  vec3u: "uint32x3",
  vec4u: "uint32x4",
  bool: "uint32",
  "vec2<bool>": "uint32x2",
  "vec3<bool>": "uint32x3",
  "vec4<bool>": "uint32x4"
};
const LOCATION_REGEX = /@location\((\d+)\)\s+([a-zA-Z0-9_]+)\s*:\s*([a-zA-Z0-9_<>]+)(?:,|\s|\)|$)/g;
function parseLocations(str, results) {
  let match;
  while ((match = LOCATION_REGEX.exec(str)) !== null) {
    const format = WGSL_TO_VERTEX_TYPES[match[3]] ?? "float32";
    results[match[2]] = {
      location: parseInt(match[1], 10),
      format,
      stride: getAttributeInfoFromFormat.getAttributeInfoFromFormat(format).stride,
      offset: 0,
      instance: false,
      start: 0
    };
  }
  LOCATION_REGEX.lastIndex = 0;
}
function stripComments(source) {
  return source.replace(/\/\/.*$/gm, "").replace(/\/\*[\s\S]*?\*\//g, "");
}
function extractAttributesFromGpuProgram({ source, entryPoint }) {
  const results = {};
  const cleanSource = stripComments(source);
  const mainVertStart = cleanSource.indexOf(`fn ${entryPoint}(`);
  if (mainVertStart === -1) {
    return results;
  }
  const arrowFunctionStart = cleanSource.indexOf("->", mainVertStart);
  if (arrowFunctionStart === -1) {
    return results;
  }
  const functionArgsSubstring = cleanSource.substring(mainVertStart, arrowFunctionStart);
  parseLocations(functionArgsSubstring, results);
  if (Object.keys(results).length === 0) {
    const structMatch = functionArgsSubstring.match(/\(\s*\w+\s*:\s*(\w+)/);
    if (structMatch) {
      const structName = structMatch[1];
      const structRegex = new RegExp(`struct\\s+${structName}\\s*\\{([^}]+)\\}`, "s");
      const structBody = cleanSource.match(structRegex);
      if (structBody) {
        parseLocations(structBody[1], results);
      }
    }
  }
  return results;
}

exports.extractAttributesFromGpuProgram = extractAttributesFromGpuProgram;
//# sourceMappingURL=extractAttributesFromGpuProgram.js.map
