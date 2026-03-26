import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { testVideoFormat } from '../utils/testVideoFormat.mjs';

"use strict";
const detectWebm = {
  extension: {
    type: ExtensionType.DetectionParser,
    priority: 0
  },
  test: async () => testVideoFormat("video/webm"),
  add: async (formats) => [...formats, "webm"],
  remove: async (formats) => formats.filter((f) => f !== "webm")
};

export { detectWebm };
//# sourceMappingURL=detectWebm.mjs.map
