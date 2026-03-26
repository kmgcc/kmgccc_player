'use strict';

var warn = require('../../utils/logging/warn.js');
var path = require('../../utils/path.js');
var convertToList = require('../utils/convertToList.js');
var isSingleItem = require('../utils/isSingleItem.js');

"use strict";
const _Loader = class _Loader {
  constructor() {
    /**
     * Options for loading assets with the loader.
     * These options will be used as defaults for all load calls made with this loader instance.
     * They can be overridden by passing options directly to the load method.
     * @example
     * ```ts
     * // Create a loader with custom default options
     * const loader = new Loader();
     * loader.loadOptions = {
     *   strategy: 'skip', // Default strategy to 'skip'
     *   retryCount: 5,   // Default retry count to 5
     *   retryDelay: 500, // Default retry delay to 500ms
     * };
     *
     * // This load call will use the loader's default options
     * await loader.load('image1.png');
     */
    this.loadOptions = { ..._Loader.defaultOptions };
    this._parsers = [];
    this._parsersValidated = false;
    /**
     * All loader parsers registered
     * @type {assets.LoaderParser[]}
     */
    this.parsers = new Proxy(this._parsers, {
      set: (target, key, value) => {
        this._parsersValidated = false;
        target[key] = value;
        return true;
      }
    });
    /** Cache loading promises that ae currently active */
    this.promiseCache = {};
  }
  /** function used for testing */
  reset() {
    this._parsersValidated = false;
    this.promiseCache = {};
  }
  /**
   * Used internally to generate a promise for the asset to be loaded.
   * @param url - The URL to be loaded
   * @param data - any custom additional information relevant to the asset being loaded
   * @returns - a promise that will resolve to an Asset for example a Texture of a JSON object
   */
  _getLoadPromiseAndParser(url, data) {
    const result = {
      promise: null,
      parser: null
    };
    result.promise = (async () => {
      let asset = null;
      let parser = null;
      if (data.parser || data.loadParser) {
        parser = this._parserHash[data.parser || data.loadParser];
        if (data.loadParser) {
          warn.warn(
            `[Assets] "loadParser" is deprecated, use "parser" instead for ${url}`
          );
        }
        if (!parser) {
          warn.warn(
            `[Assets] specified load parser "${data.parser || data.loadParser}" not found while loading ${url}`
          );
        }
      }
      if (!parser) {
        for (let i = 0; i < this.parsers.length; i++) {
          const parserX = this.parsers[i];
          if (parserX.load && parserX.test?.(url, data, this)) {
            parser = parserX;
            break;
          }
        }
        if (!parser) {
          warn.warn(`[Assets] ${url} could not be loaded as we don't know how to parse it, ensure the correct parser has been added`);
          return null;
        }
      }
      asset = await parser.load(url, data, this);
      result.parser = parser;
      for (let i = 0; i < this.parsers.length; i++) {
        const parser2 = this.parsers[i];
        if (parser2.parse) {
          if (parser2.parse && await parser2.testParse?.(asset, data, this)) {
            asset = await parser2.parse(asset, data, this) || asset;
            result.parser = parser2;
          }
        }
      }
      return asset;
    })();
    return result;
  }
  async load(assetsToLoadIn, onProgressOrOptions) {
    if (!this._parsersValidated) {
      this._validateParsers();
    }
    const options = typeof onProgressOrOptions === "function" ? { ..._Loader.defaultOptions, ...this.loadOptions, onProgress: onProgressOrOptions } : { ..._Loader.defaultOptions, ...this.loadOptions, ...onProgressOrOptions || {} };
    const { onProgress, onError, strategy, retryCount, retryDelay } = options;
    let count = 0;
    const assets = {};
    const singleAsset = isSingleItem.isSingleItem(assetsToLoadIn);
    const assetsToLoad = convertToList.convertToList(assetsToLoadIn, (item) => ({
      alias: [item],
      src: item,
      data: {}
    }));
    const total = assetsToLoad.reduce((sum, asset) => sum + (asset.progressSize || 1), 0);
    const promises = assetsToLoad.map(async (asset) => {
      const url = path.path.toAbsolute(asset.src);
      if (assets[asset.src]) return;
      await this._loadAssetWithRetry(url, asset, { onProgress, onError, strategy, retryCount, retryDelay }, assets);
      count += asset.progressSize || 1;
      if (onProgress) onProgress(count / total);
    });
    await Promise.all(promises);
    return singleAsset ? assets[assetsToLoad[0].src] : assets;
  }
  /**
   * Unloads one or more assets. Any unloaded assets will be destroyed, freeing up memory for your app.
   * The parser that created the asset, will be the one that unloads it.
   * @example
   * // Single asset:
   * const asset = await Loader.load('cool.png');
   *
   * await Loader.unload('cool.png');
   *
   * console.log(asset.destroyed); // true
   * @param assetsToUnloadIn - urls that you want to unload, or a single one!
   */
  async unload(assetsToUnloadIn) {
    const assetsToUnload = convertToList.convertToList(assetsToUnloadIn, (item) => ({
      alias: [item],
      src: item
    }));
    const promises = assetsToUnload.map(async (asset) => {
      const url = path.path.toAbsolute(asset.src);
      const loadPromise = this.promiseCache[url];
      if (loadPromise) {
        const loadedAsset = await loadPromise.promise;
        delete this.promiseCache[url];
        await loadPromise.parser?.unload?.(loadedAsset, asset, this);
      }
    });
    await Promise.all(promises);
  }
  /** validates our parsers, right now it only checks for name conflicts but we can add more here as required! */
  _validateParsers() {
    this._parsersValidated = true;
    this._parserHash = this._parsers.filter((parser) => parser.name || parser.id).reduce((hash, parser) => {
      if (!parser.name && !parser.id) {
        warn.warn(`[Assets] parser should have an id`);
      } else if (hash[parser.name] || hash[parser.id]) {
        warn.warn(`[Assets] parser id conflict "${parser.id}"`);
      }
      hash[parser.name] = parser;
      if (parser.id) hash[parser.id] = parser;
      return hash;
    }, {});
  }
  async _loadAssetWithRetry(url, asset, options, assets) {
    let attempt = 0;
    const { onError, strategy, retryCount, retryDelay } = options;
    const wait = (ms) => new Promise((r) => setTimeout(r, ms));
    while (true) {
      try {
        if (!this.promiseCache[url]) {
          this.promiseCache[url] = this._getLoadPromiseAndParser(url, asset);
        }
        assets[asset.src] = await this.promiseCache[url].promise;
        return;
      } catch (e) {
        delete this.promiseCache[url];
        delete assets[asset.src];
        attempt++;
        const isLast = strategy !== "retry" || attempt > retryCount;
        if (strategy === "retry" && !isLast) {
          if (onError) onError(e, asset);
          await wait(retryDelay);
          continue;
        }
        if (strategy === "skip") {
          if (onError) onError(e, asset);
          return;
        }
        if (onError) onError(e, asset);
        const error = new Error(`[Loader.load] Failed to load ${url}.
${e}`);
        if (e instanceof Error && e.stack) {
          error.stack = e.stack;
        }
        throw error;
      }
    }
  }
};
/**
 * Default options for loading assets
 * @example
 * ```ts
 * // Change default load options globally
 * Loader.defaultOptions = {
 *   strategy: 'skip', // Change default strategy to 'skip'
 *   retryCount: 5,   // Change default retry count to 5
 *   retryDelay: 500, // Change default retry delay to 500ms
 * };
 * ```
 */
_Loader.defaultOptions = {
  onProgress: void 0,
  onError: void 0,
  strategy: "throw",
  retryCount: 3,
  retryDelay: 250
};
let Loader = _Loader;

exports.Loader = Loader;
//# sourceMappingURL=Loader.js.map
