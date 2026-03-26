import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { UboSystem } from '../shared/shader/UboSystem.mjs';
import { createUboElementsWGSL } from './shader/utils/createUboElementsWGSL.mjs';
import { createUboSyncFunctionWGSL } from './shader/utils/createUboSyncFunctionWGSL.mjs';

"use strict";
class GpuUboSystem extends UboSystem {
  constructor() {
    super({
      createUboElements: createUboElementsWGSL,
      generateUboSync: createUboSyncFunctionWGSL
    });
  }
}
/** @ignore */
GpuUboSystem.extension = {
  type: [ExtensionType.WebGPUSystem],
  name: "ubo"
};

export { GpuUboSystem };
//# sourceMappingURL=GpuUboSystem.mjs.map
