import { ExtensionType } from '../../../extensions/Extensions.mjs';

"use strict";
const imageFormats = ["png", "jpg", "jpeg"];
const detectDefaults = {
  extension: {
    type: ExtensionType.DetectionParser,
    priority: -1
  },
  test: () => Promise.resolve(true),
  add: async (formats) => [...formats, ...imageFormats],
  remove: async (formats) => formats.filter((f) => !imageFormats.includes(f))
};

export { detectDefaults };
//# sourceMappingURL=detectDefaults.mjs.map
