import { ExtensionType } from '../extensions/Extensions.mjs';

"use strict";
const browserExt = {
  extension: {
    type: ExtensionType.Environment,
    name: "browser",
    priority: -1
  },
  test: () => true,
  load: async () => {
    await import('./browserAll.mjs');
  }
};

export { browserExt };
//# sourceMappingURL=browserExt.mjs.map
