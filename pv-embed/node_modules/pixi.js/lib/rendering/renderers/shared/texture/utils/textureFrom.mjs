import { Cache } from '../../../../../assets/cache/Cache.mjs';
import { extensions, ExtensionType } from '../../../../../extensions/Extensions.mjs';
import { TextureSource } from '../sources/TextureSource.mjs';
import { Texture } from '../Texture.mjs';

"use strict";
const sources = [];
extensions.handleByList(ExtensionType.TextureSource, sources);
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
  if (!skipCache && Cache.has(resource)) {
    return Cache.get(resource);
  }
  const texture = new Texture({ source: textureSourceFrom(opts) });
  texture.on("destroy", () => {
    if (Cache.has(resource)) {
      Cache.remove(resource);
    }
  });
  if (!skipCache) {
    Cache.set(resource, texture);
  }
  return texture;
}
function textureFrom(id, skipCache = false) {
  if (typeof id === "string") {
    return Cache.get(id);
  } else if (id instanceof TextureSource) {
    return new Texture({ source: id });
  }
  return resourceToTexture(id, skipCache);
}
Texture.from = textureFrom;
TextureSource.from = textureSourceFrom;

export { autoDetectSource, resourceToTexture, textureFrom };
//# sourceMappingURL=textureFrom.mjs.map
