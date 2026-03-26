'use strict';

var Texture = require('../../../../../rendering/renderers/shared/texture/Texture.js');
var warn = require('../../../../../utils/logging/warn.js');
var Cache = require('../../../../cache/Cache.js');

"use strict";
function createTexture(source, loader, url) {
  source.label = url;
  source._sourceOrigin = url;
  const texture = new Texture.Texture({
    source,
    label: url
  });
  const unload = () => {
    delete loader.promiseCache[url];
    if (Cache.Cache.has(url)) {
      Cache.Cache.remove(url);
    }
  };
  texture.source.once("destroy", () => {
    if (loader.promiseCache[url]) {
      warn.warn("[Assets] A TextureSource managed by Assets was destroyed instead of unloaded! Use Assets.unload() instead of destroying the TextureSource.");
      unload();
    }
  });
  texture.once("destroy", () => {
    if (!source.destroyed) {
      warn.warn("[Assets] A Texture managed by Assets was destroyed instead of unloaded! Use Assets.unload() instead of destroying the Texture.");
      unload();
    }
  });
  return texture;
}

exports.createTexture = createTexture;
//# sourceMappingURL=createTexture.js.map
