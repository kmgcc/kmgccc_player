import EventEmitter from 'eventemitter3';
import { Cache } from '../../../../assets/cache/Cache.mjs';
import { uid } from '../../../../utils/data/uid.mjs';
import { CubeTextureSource } from './sources/CubeTextureSource.mjs';
import { Texture } from './Texture.mjs';

"use strict";
const faceKeys = ["left", "right", "top", "bottom", "front", "back"];
function getCubeCacheKey(faceIds, options) {
  const opts = options ? { ...options } : {};
  delete opts.label;
  const optKeys = Object.keys(opts).sort();
  const optPart = optKeys.length ? `|${optKeys.map((k) => `${k}=${String(opts[k])}`).join("&")}` : "";
  const facesPart = faceKeys.map((k) => faceIds[k]).join(",");
  return `cube:${facesPart}${optPart}`;
}
class CubeTexture extends EventEmitter {
  constructor(options) {
    super();
    /** unique id for this cube texture */
    this.uid = uid("cubeTexture");
    /** Has the texture been destroyed? */
    this.destroyed = false;
    const { label, source } = options;
    this.label = label;
    this.source = source;
    this.source.label = this.label ?? this.source.label;
  }
  static from(options, skipCache = false) {
    if (options instanceof CubeTextureSource) {
      return new CubeTexture({ source: options });
    }
    const { faces, ...sourceOptions } = options;
    let cacheKey = null;
    const isFaceIds = faceKeys.every((key) => typeof faces[key] === "string");
    if (!skipCache && isFaceIds) {
      cacheKey = getCubeCacheKey(faces, sourceOptions);
      if (Cache.has(cacheKey)) {
        return Cache.get(cacheKey);
      }
    }
    const toTexture = (input) => {
      if (input.isTexture) return input;
      return Texture.from(input);
    };
    const faceSources = {};
    for (const key of faceKeys) {
      faceSources[key] = toTexture(faces[key]).source;
    }
    const cubeTexture = new CubeTexture({
      source: new CubeTextureSource({
        ...sourceOptions,
        faces: faceSources
      }),
      label: sourceOptions.label
    });
    if (cacheKey) {
      Cache.set(cacheKey, cubeTexture);
      cubeTexture.once("destroy", () => {
        if (Cache.has(cacheKey)) {
          Cache.remove(cacheKey);
        }
      });
    }
    return cubeTexture;
  }
  /**
   * Destroy this CubeTexture.
   * @param destroySource - If true, destroys the underlying {@link CubeTextureSource}.
   */
  destroy(destroySource = false) {
    if (this.destroyed) return;
    this.destroyed = true;
    if (destroySource) {
      this.source.destroy();
    }
    this.emit("destroy", this);
    this.removeAllListeners();
  }
}

export { CubeTexture };
//# sourceMappingURL=CubeTexture.mjs.map
