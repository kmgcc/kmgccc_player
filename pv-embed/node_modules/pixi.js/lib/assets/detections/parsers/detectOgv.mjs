import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { testVideoFormat } from '../utils/testVideoFormat.mjs';

"use strict";
const detectOgv = {
  extension: {
    type: ExtensionType.DetectionParser,
    priority: 0
  },
  test: async () => testVideoFormat("video/ogg"),
  add: async (formats) => [...formats, "ogv"],
  remove: async (formats) => formats.filter((f) => f !== "ogv")
};

export { detectOgv };
//# sourceMappingURL=detectOgv.mjs.map
