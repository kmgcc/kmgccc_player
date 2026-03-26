'use strict';

var createUboElementsSTD40 = require('../../rendering/renderers/gl/shader/utils/createUboElementsSTD40.js');
var createUboElementsWGSL = require('../../rendering/renderers/gpu/shader/utils/createUboElementsWGSL.js');
var uniformParsers = require('../../rendering/renderers/shared/shader/utils/uniformParsers.js');
var uboSyncFunctions = require('./uboSyncFunctions.js');

"use strict";
function generateUboSyncPolyfillSTD40(uboElements) {
  return generateUboSyncPolyfill(
    uboElements,
    uboSyncFunctions.uboSingleFunctionsSTD40,
    (uboElement) => {
      const rowSize = Math.max(createUboElementsSTD40.WGSL_TO_STD40_SIZE[uboElement.data.type] / 16, 1);
      const elementSize = uboElement.data.value.length / uboElement.data.size;
      const remainder = (4 - elementSize % 4) % 4;
      return (_name, data, offset, _uv, v) => {
        let t = 0;
        for (let i = 0; i < uboElement.data.size * rowSize; i++) {
          for (let j = 0; j < elementSize; j++) {
            data[offset++] = v[t++];
          }
          offset += remainder;
        }
      };
    }
  );
}
function generateUboSyncPolyfillWGSL(uboElements) {
  return generateUboSyncPolyfill(
    uboElements,
    uboSyncFunctions.uboSingleFunctionsWGSL,
    (uboElement) => {
      const { size, align } = createUboElementsWGSL.WGSL_ALIGN_SIZE_DATA[uboElement.data.type];
      const remainder = (size - align) / 4;
      return (_name, data, offset, _uv, v) => {
        let t = 0;
        for (let i = 0; i < uboElement.data.size * (size / 4); i++) {
          for (let j = 0; j < size / 4; j++) {
            data[offset++] = v[t++];
          }
          offset += remainder;
        }
      };
    }
  );
}
function generateUboSyncPolyfill(uboElements, uboFunctions, arrayUploadFunction) {
  const functionMap = {};
  for (const i in uboElements) {
    const uboElement = uboElements[i];
    const uniform = uboElement.data;
    let parsed = false;
    functionMap[uniform.name] = {
      offset: uboElement.offset / 4,
      func: null
    };
    for (let j = 0; j < uniformParsers.uniformParsers.length; j++) {
      const parser = uniformParsers.uniformParsers[j];
      if (uniform.type === parser.type && parser.test(uniform)) {
        functionMap[uniform.name].func = uboSyncFunctions.uboParserFunctions[j];
        parsed = true;
        break;
      }
    }
    if (!parsed) {
      if (uniform.size === 1) {
        functionMap[uniform.name].func = uboFunctions[uniform.type];
      } else {
        functionMap[uniform.name].func = arrayUploadFunction(uboElement);
      }
    }
  }
  return (uniforms, data, offset) => {
    for (const i in functionMap) {
      functionMap[i].func(i, data, offset + functionMap[i].offset, uniforms, uniforms[i]);
    }
  };
}

exports.generateUboSyncPolyfillSTD40 = generateUboSyncPolyfillSTD40;
exports.generateUboSyncPolyfillWGSL = generateUboSyncPolyfillWGSL;
//# sourceMappingURL=generateUboSyncPolyfill.js.map
