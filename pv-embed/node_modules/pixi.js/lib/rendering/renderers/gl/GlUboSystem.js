'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var UboSystem = require('../shared/shader/UboSystem.js');
var createUboElementsSTD40 = require('./shader/utils/createUboElementsSTD40.js');
var createUboSyncSTD40 = require('./shader/utils/createUboSyncSTD40.js');

"use strict";
class GlUboSystem extends UboSystem.UboSystem {
  constructor() {
    super({
      createUboElements: createUboElementsSTD40.createUboElementsSTD40,
      generateUboSync: createUboSyncSTD40.createUboSyncFunctionSTD40
    });
  }
}
/** @ignore */
GlUboSystem.extension = {
  type: [Extensions.ExtensionType.WebGLSystem],
  name: "ubo"
};

exports.GlUboSystem = GlUboSystem;
//# sourceMappingURL=GlUboSystem.js.map
