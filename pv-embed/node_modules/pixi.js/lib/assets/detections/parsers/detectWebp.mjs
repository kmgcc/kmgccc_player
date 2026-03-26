import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { testImageFormat } from '../utils/testImageFormat.mjs';

"use strict";
const detectWebp = {
  extension: {
    type: ExtensionType.DetectionParser,
    priority: 0
  },
  test: async () => testImageFormat(
    "data:image/webp;base64,UklGRh4AAABXRUJQVlA4TBEAAAAvAAAAAAfQ//73v/+BiOh/AAA="
  ),
  add: async (formats) => [...formats, "webp"],
  remove: async (formats) => formats.filter((f) => f !== "webp")
};

export { detectWebp };
//# sourceMappingURL=detectWebp.mjs.map
