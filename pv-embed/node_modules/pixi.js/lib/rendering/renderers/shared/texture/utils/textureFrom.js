'use strict';

var Cache = require('../../../../../assets/cache/Cache.js');
var Extensions = require('../../../../../extensions/Extensions.js');
var TextureSource = require('../sources/TextureSource.js');
var Texture = require('../Texture.js');

"use strict";
const sources = [];
Extensions.extensions.handleByList(Extensions.ExtensionType.TextureSource, sources);
function autoDetectSource(options = {}) {
  return textureSourceFrom(options);
}
function textureSourceFrom(options = {}) {
  const hasResource = options && options.resource;
  const res = hasResource ? options.resource : options;
  const opts = hasResource ? options : { resource: options };
  for (let i = 0; i < sources.length; i++) {
    const Source = sources[i];
    if (Source.test(res)) {
      return new Source(opts);
    }
  }
  throw new Error(`Could not find a source type for resource: ${opts.resource}`);
}
function resourceToTexture(options = {}, skipCache = false) {
  const hasResource = options && options.resource;
  const resource = hasResource ? options.resource : options;
  const opts = hasResource ? options : { resource: options };
  if (!skipCache && Cache.Cache.has(resource)) {
    return Cache.Cache.get(resource);
  }
  const texture = new Texture.Texture({ source: textureSourceFrom(opts) });
  texture.on("destroy", () => {
    if (Cache.Cache.has(resource)) {
      Cache.Cache.remove(resource);
    }
  });
  if (!skipCache) {
    Cache.Cache.set(resource, texture);
  }
  return texture;
}
function textureFrom(id, skipCache = false) {
  if (typeof id === "string") {
    return Cache.Cache.get(id);
  } else if (id instanceof TextureSource.TextureSource) {
    return new Texture.Texture({ source: id });
  }
  return resourceToTexture(id, skipCache);
}
Texture.Texture.from = textureFrom;
TextureSource.TextureSource.from = textureSourceFrom;

exports.autoDetectSource = autoDetectSource;
exports.resourceToTexture = resourceToTexture;
exports.textureFrom = textureFrom;
//# sourceMappingURL=textureFrom.js.map
