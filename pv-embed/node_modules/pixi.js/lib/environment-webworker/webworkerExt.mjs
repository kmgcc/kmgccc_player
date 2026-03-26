import { ExtensionType } from '../extensions/Extensions.mjs';

"use strict";
const webworkerExt = {
  extension: {
    type: ExtensionType.Environment,
    name: "webworker",
    priority: 0
  },
  test: () => typeof self !== "undefined" && self.WorkerGlobalScope !== void 0,
  load: async () => {
    await import('./webworkerAll.mjs');
  }
};

export { webworkerExt };
//# sourceMappingURL=webworkerExt.mjs.map
