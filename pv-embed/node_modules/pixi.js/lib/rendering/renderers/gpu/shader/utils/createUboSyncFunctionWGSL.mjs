import { createUboSyncFunction } from '../../../shared/shader/utils/createUboSyncFunction.mjs';
import { uboSyncFunctionsWGSL } from '../../../shared/shader/utils/uboSyncFunctions.mjs';
import { generateArraySyncWGSL } from './generateArraySyncWGSL.mjs';

"use strict";
function createUboSyncFunctionWGSL(uboElements) {
  return createUboSyncFunction(
    uboElements,
    "uboWgsl",
    generateArraySyncWGSL,
    uboSyncFunctionsWGSL
  );
}

export { createUboSyncFunctionWGSL };
//# sourceMappingURL=createUboSyncFunctionWGSL.mjs.map
