'use strict';

var uniformParsers = require('./uniformParsers.js');

"use strict";
function createUboSyncFunction(uboElements, parserCode, arrayGenerationFunction, singleSettersMap) {
  const funcFragments = [`
        var v = null;
        var v2 = null;
        var t = 0;
        var index = 0;
        var name = null;
        var arrayOffset = null;
    `];
  let prev = 0;
  for (let i = 0; i < uboElements.length; i++) {
    const uboElement = uboElements[i];
    const name = uboElement.data.name;
    let parsed = false;
    let offset = 0;
    for (let j = 0; j < uniformParsers.uniformParsers.length; j++) {
      const uniformParser = uniformParsers.uniformParsers[j];
      if (uniformParser.test(uboElement.data)) {
        offset = uboElement.offset / 4;
        funcFragments.push(
          `name = "${name}";`,
          `offset += ${offset - prev};`,
          uniformParsers.uniformParsers[j][parserCode] || uniformParsers.uniformParsers[j].ubo
        );
        parsed = true;
        break;
      }
    }
    if (!parsed) {
      if (uboElement.data.size > 1) {
        offset = uboElement.offset / 4;
        funcFragments.push(arrayGenerationFunction(uboElement, offset - prev));
      } else {
        const template = singleSettersMap[uboElement.data.type];
        offset = uboElement.offset / 4;
        funcFragments.push(
          /* wgsl */
          `
                    v = uv.${name};
                    offset += ${offset - prev};
                    ${template};
                `
        );
      }
    }
    prev = offset;
  }
  const fragmentSrc = funcFragments.join("\n");
  return new Function(
    "uv",
    "data",
    "dataInt32",
    "offset",
    fragmentSrc
  );
}

exports.createUboSyncFunction = createUboSyncFunction;
//# sourceMappingURL=createUboSyncFunction.js.map
