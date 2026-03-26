import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { UboSystem } from '../shared/shader/UboSystem.mjs';
import { createUboElementsSTD40 } from './shader/utils/createUboElementsSTD40.mjs';
import { createUboSyncFunctionSTD40 } from './shader/utils/createUboSyncSTD40.mjs';

"use strict";
class GlUboSystem extends UboSystem {
  constructor() {
    super({
      createUboElements: createUboElementsSTD40,
      generateUboSync: createUboSyncFunctionSTD40
    });
  }
}
/** @ignore */
GlUboSystem.extension = {
  type: [ExtensionType.WebGLSystem],
  name: "ubo"
};

export { GlUboSystem };
//# sourceMappingURL=GlUboSystem.mjs.map
