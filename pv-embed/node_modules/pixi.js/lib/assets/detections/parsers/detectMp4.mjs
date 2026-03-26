import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { testVideoFormat } from '../utils/testVideoFormat.mjs';

"use strict";
const detectMp4 = {
  extension: {
    type: ExtensionType.DetectionParser,
    priority: 0
  },
  test: async () => testVideoFormat("video/mp4"),
  add: async (formats) => [...formats, "mp4", "m4v"],
  remove: async (formats) => formats.filter((f) => f !== "mp4" && f !== "m4v")
};

export { detectMp4 };
//# sourceMappingURL=detectMp4.mjs.map
