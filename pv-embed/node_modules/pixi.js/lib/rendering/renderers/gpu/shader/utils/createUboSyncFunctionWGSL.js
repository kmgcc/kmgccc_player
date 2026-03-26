'use strict';

var createUboSyncFunction = require('../../../shared/shader/utils/createUboSyncFunction.js');
var uboSyncFunctions = require('../../../shared/shader/utils/uboSyncFunctions.js');
var generateArraySyncWGSL = require('./generateArraySyncWGSL.js');

"use strict";
function createUboSyncFunctionWGSL(uboElements) {
  return createUboSyncFunction.createUboSyncFunction(
    uboElements,
    "uboWgsl",
    generateArraySyncWGSL.generateArraySyncWGSL,
    uboSyncFunctions.uboSyncFunctionsWGSL
  );
}

exports.createUboSyncFunctionWGSL = createUboSyncFunctionWGSL;
//# sourceMappingURL=createUboSyncFunctionWGSL.js.map
