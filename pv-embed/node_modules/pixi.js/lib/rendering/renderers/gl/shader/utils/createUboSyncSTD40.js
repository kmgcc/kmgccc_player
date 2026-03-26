'use strict';

var createUboSyncFunction = require('../../../shared/shader/utils/createUboSyncFunction.js');
var uboSyncFunctions = require('../../../shared/shader/utils/uboSyncFunctions.js');
var generateArraySyncSTD40 = require('./generateArraySyncSTD40.js');

"use strict";
function createUboSyncFunctionSTD40(uboElements) {
  return createUboSyncFunction.createUboSyncFunction(
    uboElements,
    "uboStd40",
    generateArraySyncSTD40.generateArraySyncSTD40,
    uboSyncFunctions.uboSyncFunctionsSTD40
  );
}

exports.createUboSyncFunctionSTD40 = createUboSyncFunctionSTD40;
//# sourceMappingURL=createUboSyncSTD40.js.map
