import { createUboSyncFunction } from '../../../shared/shader/utils/createUboSyncFunction.mjs';
import { uboSyncFunctionsSTD40 } from '../../../shared/shader/utils/uboSyncFunctions.mjs';
import { generateArraySyncSTD40 } from './generateArraySyncSTD40.mjs';

"use strict";
function createUboSyncFunctionSTD40(uboElements) {
  return createUboSyncFunction(
    uboElements,
    "uboStd40",
    generateArraySyncSTD40,
    uboSyncFunctionsSTD40
  );
}

export { createUboSyncFunctionSTD40 };
//# sourceMappingURL=createUboSyncSTD40.mjs.map
