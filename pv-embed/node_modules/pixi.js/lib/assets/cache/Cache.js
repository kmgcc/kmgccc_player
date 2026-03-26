'use strict';

var warn = require('../../utils/logging/warn.js');
var convertToList = require('../utils/convertToList.js');

"use strict";
class CacheClass {
  constructor() {
    this._parsers = [];
    this._cache = /* @__PURE__ */ new Map();
    this._cacheMap = /* @__PURE__ */ new Map();
  }
  /** Clear all entries. */
  reset() {
    this._cacheMap.clear();
    this._cache.clear();
  }
  /**
   * Check if the key exists
   * @param key - The key to check
   */
  has(key) {
    return this._cache.has(key);
  }
  /**
   * Fetch entry by key
   * @param key - The key of the entry to get
   */
  get(key) {
    const result = this._cache.get(key);
    if (!result) {
      warn.warn(`[Assets] Asset id ${key} was not found in the Cache`);
    }
    return result;
  }
  /**
   * Set a value by key or keys name
   * @param key - The key or keys to set
   * @param value - The value to store in the cache or from which cacheable assets will be derived.
   */
  set(key, value) {
    const keys = convertToList.convertToList(key);
    let cacheableAssets;
    for (let i = 0; i < this.parsers.length; i++) {
      const parser = this.parsers[i];
      if (parser.test(value)) {
        cacheableAssets = parser.getCacheableAssets(keys, value);
        break;
      }
    }
    const cacheableMap = new Map(Object.entries(cacheableAssets || {}));
    if (!cacheableAssets) {
      keys.forEach((key2) => {
        cacheableMap.set(key2, value);
      });
    }
    const cacheKeys = [...cacheableMap.keys()];
    const cachedAssets = {
      cacheKeys,
      keys
    };
    keys.forEach((key2) => {
      this._cacheMap.set(key2, cachedAssets);
    });
    cacheKeys.forEach((key2) => {
      const val = cacheableAssets ? cacheableAssets[key2] : value;
      if (this._cache.has(key2) && this._cache.get(key2) !== val) {
        warn.warn("[Cache] already has key:", key2);
      }
      this._cache.set(key2, cacheableMap.get(key2));
    });
  }
  /**
   * Remove entry by key
   *
   * This function will also remove any associated alias from the cache also.
   * @param key - The key of the entry to remove
   */
  remove(key) {
    if (!this._cacheMap.has(key)) {
      warn.warn(`[Assets] Asset id ${key} was not found in the Cache`);
      return;
    }
    const cacheMap = this._cacheMap.get(key);
    const cacheKeys = cacheMap.cacheKeys;
    cacheKeys.forEach((key2) => {
      this._cache.delete(key2);
    });
    cacheMap.keys.forEach((key2) => {
      this._cacheMap.delete(key2);
    });
  }
  /**
   * All loader parsers registered
   * @advanced
   */
  get parsers() {
    return this._parsers;
  }
}
const Cache = new CacheClass();

exports.Cache = Cache;
//# sourceMappingURL=Cache.js.map
