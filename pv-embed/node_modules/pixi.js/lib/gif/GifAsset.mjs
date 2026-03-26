import { DOMAdapter } from '../environment/adapter.mjs';
import { ExtensionType } from '../extensions/Extensions.mjs';
import { path } from '../utils/path.mjs';
import { GifSource } from './GifSource.mjs';

"use strict";
const GifAsset = {
  extension: ExtensionType.Asset,
  detection: {
    test: async () => true,
    add: async (formats) => [...formats, "gif"],
    remove: async (formats) => formats.filter((format) => format !== "gif")
  },
  loader: {
    /** used for deprecation purposes */
    name: "gifLoader",
    id: "gif",
    test: (url) => path.extname(url) === ".gif" || url.startsWith("data:image/gif"),
    load: async (url, asset) => {
      const response = await DOMAdapter.get().fetch(url);
      const buffer = await response.arrayBuffer();
      return GifSource.from(buffer, asset?.data);
    },
    unload: async (asset) => {
      asset.destroy();
    }
  }
};

export { GifAsset };
//# sourceMappingURL=GifAsset.mjs.map
