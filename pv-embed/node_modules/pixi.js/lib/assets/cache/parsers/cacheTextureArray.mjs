import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { Texture } from '../../../rendering/renderers/shared/texture/Texture.mjs';

"use strict";
const cacheTextureArray = {
  extension: {
    type: ExtensionType.CacheParser,
    name: "cacheTextureArray"
  },
  test: (asset) => Array.isArray(asset) && asset.every((t) => t instanceof Texture),
  getCacheableAssets: (keys, asset) => {
    const out = {};
    keys.forEach((key) => {
      asset.forEach((item, i) => {
        out[key + (i === 0 ? "" : i + 1)] = item;
      });
    });
    return out;
  }
};

export { cacheTextureArray };
//# sourceMappingURL=cacheTextureArray.mjs.map
