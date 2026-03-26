import { WGSL_TO_STD40_SIZE } from '../../rendering/renderers/gl/shader/utils/createUboElementsSTD40.mjs';
import { WGSL_ALIGN_SIZE_DATA } from '../../rendering/renderers/gpu/shader/utils/createUboElementsWGSL.mjs';
import { uniformParsers } from '../../rendering/renderers/shared/shader/utils/uniformParsers.mjs';
import { uboSingleFunctionsSTD40, uboSingleFunctionsWGSL, uboParserFunctions } from './uboSyncFunctions.mjs';

"use strict";
function generateUboSyncPolyfillSTD40(uboElements) {
  return generateUboSyncPolyfill(
    uboElements,
    uboSingleFunctionsSTD40,
    (uboElement) => {
      const rowSize = Math.max(WGSL_TO_STD40_SIZE[uboElement.data.type] / 16, 1);
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
    uboSingleFunctionsWGSL,
    (uboElement) => {
      const { size, align } = WGSL_ALIGN_SIZE_DATA[uboElement.data.type];
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
    for (let j = 0; j < uniformParsers.length; j++) {
      const parser = uniformParsers[j];
      if (uniform.type === parser.type && parser.test(uniform)) {
        functionMap[uniform.name].func = uboParserFunctions[j];
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

export { generateUboSyncPolyfillSTD40, generateUboSyncPolyfillWGSL };
//# sourceMappingURL=generateUboSyncPolyfill.mjs.map
