import { Texture } from '../../../../../rendering/renderers/shared/texture/Texture.mjs';
import { warn } from '../../../../../utils/logging/warn.mjs';
import { Cache } from '../../../../cache/Cache.mjs';

"use strict";
function createTexture(source, loader, url) {
  source.label = url;
  source._sourceOrigin = url;
  const texture = new Texture({
    source,
    label: url
  });
  const unload = () => {
    delete loader.promiseCache[url];
    if (Cache.has(url)) {
      Cache.remove(url);
    }
  };
  texture.source.once("destroy", () => {
    if (loader.promiseCache[url]) {
      warn("[Assets] A TextureSource managed by Assets was destroyed instead of unloaded! Use Assets.unload() instead of destroying the TextureSource.");
      unload();
    }
  });
  texture.once("destroy", () => {
    if (!source.destroyed) {
      warn("[Assets] A Texture managed by Assets was destroyed instead of unloaded! Use Assets.unload() instead of destroying the Texture.");
      unload();
    }
  });
  return texture;
}

export { createTexture };
//# sourceMappingURL=createTexture.mjs.map
