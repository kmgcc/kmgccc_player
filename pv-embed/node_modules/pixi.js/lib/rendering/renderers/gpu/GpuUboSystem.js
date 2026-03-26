'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var UboSystem = require('../shared/shader/UboSystem.js');
var createUboElementsWGSL = require('./shader/utils/createUboElementsWGSL.js');
var createUboSyncFunctionWGSL = require('./shader/utils/createUboSyncFunctionWGSL.js');

"use strict";
class GpuUboSystem extends UboSystem.UboSystem {
  constructor() {
    super({
      createUboElements: createUboElementsWGSL.createUboElementsWGSL,
      generateUboSync: createUboSyncFunctionWGSL.createUboSyncFunctionWGSL
    });
  }
}
/** @ignore */
GpuUboSystem.extension = {
  type: [Extensions.ExtensionType.WebGPUSystem],
  name: "ubo"
};

exports.GpuUboSystem = GpuUboSystem;
//# sourceMappingURL=GpuUboSystem.js.map
