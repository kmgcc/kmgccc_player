import { warn } from '../../utils/logging/warn.mjs';
import { path } from '../../utils/path.mjs';
import { convertToList } from '../utils/convertToList.mjs';
import { createStringVariations } from '../utils/createStringVariations.mjs';
import { isSingleItem } from '../utils/isSingleItem.mjs';

"use strict";
class Resolver {
  constructor() {
    this._defaultBundleIdentifierOptions = {
      connector: "-",
      createBundleAssetId: (bundleId, assetId) => `${bundleId}${this._bundleIdConnector}${assetId}`,
      extractAssetIdFromBundle: (bundleId, assetBundleId) => assetBundleId.replace(`${bundleId}${this._bundleIdConnector}`, "")
    };
    /** The character that is used to connect the bundleId and the assetId when generating a bundle asset id key */
    this._bundleIdConnector = this._defaultBundleIdentifierOptions.connector;
    /**
     * A function that generates a bundle asset id key from a bundleId and an assetId
     * @param bundleId - the bundleId
     * @param assetId  - the assetId
     * @returns the bundle asset id key
     */
    this._createBundleAssetId = this._defaultBundleIdentifierOptions.createBundleAssetId;
    /**
     * A function that generates an assetId from a bundle asset id key. This is the reverse of generateBundleAssetId
     * @param bundleId - the bundleId
     * @param assetBundleId - the bundle asset id key
     * @returns the assetId
     */
    this._extractAssetIdFromBundle = this._defaultBundleIdentifierOptions.extractAssetIdFromBundle;
    this._assetMap = {};
    this._preferredOrder = [];
    this._parsers = [];
    this._resolverHash = {};
    this._bundles = {};
  }
  /**
   * Override how the resolver deals with generating bundle ids.
   * must be called before any bundles are added
   * @param bundleIdentifier - the bundle identifier options
   */
  setBundleIdentifier(bundleIdentifier) {
    this._bundleIdConnector = bundleIdentifier.connector ?? this._bundleIdConnector;
    this._createBundleAssetId = bundleIdentifier.createBundleAssetId ?? this._createBundleAssetId;
    this._extractAssetIdFromBundle = bundleIdentifier.extractAssetIdFromBundle ?? this._extractAssetIdFromBundle;
    if (this._extractAssetIdFromBundle("foo", this._createBundleAssetId("foo", "bar")) !== "bar") {
      throw new Error("[Resolver] GenerateBundleAssetId are not working correctly");
    }
  }
  /**
   * Let the resolver know which assets you prefer to use when resolving assets.
   * Multiple prefer user defined rules can be added.
   * @example
   * resolver.prefer({
   *     // first look for something with the correct format, and then then correct resolution
   *     priority: ['format', 'resolution'],
   *     params:{
   *         format:'webp', // prefer webp images
   *         resolution: 2, // prefer a resolution of 2
   *     }
   * })
   * resolver.add('foo', ['bar@2x.webp', 'bar@2x.png', 'bar.webp', 'bar.png']);
   * resolver.resolveUrl('foo') // => 'bar@2x.webp'
   * @param preferOrders - the prefer options
   */
  prefer(...preferOrders) {
    preferOrders.forEach((prefer) => {
      this._preferredOrder.push(prefer);
      if (!prefer.priority) {
        prefer.priority = Object.keys(prefer.params);
      }
    });
    this._resolverHash = {};
  }
  /**
   * Set the base path to prepend to all urls when resolving
   * @example
   * resolver.basePath = 'https://home.com/';
   * resolver.add('foo', 'bar.ong');
   * resolver.resolveUrl('foo', 'bar.png'); // => 'https://home.com/bar.png'
   * @param basePath - the base path to use
   */
  set basePath(basePath) {
    this._basePath = basePath;
  }
  get basePath() {
    return this._basePath;
  }
  /**
   * Set the root path for root-relative URLs. By default the `basePath`'s root is used. If no `basePath` is set, then the
   * default value for browsers is `window.location.origin`
   * @example
   * // Application hosted on https://home.com/some-path/index.html
   * resolver.basePath = 'https://home.com/some-path/';
   * resolver.rootPath = 'https://home.com/';
   * resolver.add('foo', '/bar.png');
   * resolver.resolveUrl('foo', '/bar.png'); // => 'https://home.com/bar.png'
   * @param rootPath - the root path to use
   */
  set rootPath(rootPath) {
    this._rootPath = rootPath;
  }
  get rootPath() {
    return this._rootPath;
  }
  /**
   * All the active URL parsers that help the parser to extract information and create
   * an asset object-based on parsing the URL itself.
   *
   * Can be added using the extensions API
   * @example
   * resolver.add('foo', [
   *     {
   *         resolution: 2,
   *         format: 'png',
   *         src: 'image@2x.png',
   *     },
   *     {
   *         resolution:1,
   *         format:'png',
   *         src: 'image.png',
   *     },
   * ]);
   *
   * // With a url parser the information such as resolution and file format could extracted from the url itself:
   * extensions.add({
   *     extension: ExtensionType.ResolveParser,
   *     test: loadTextures.test, // test if url ends in an image
   *     parse: (value: string) =>
   *     ({
   *         resolution: parseFloat(Resolver.RETINA_PREFIX.exec(value)?.[1] ?? '1'),
   *         format: value.split('.').pop(),
   *         src: value,
   *     }),
   * });
   *
   * // Now resolution and format can be extracted from the url
   * resolver.add('foo', [
   *     'image@2x.png',
   *     'image.png',
   * ]);
   */
  get parsers() {
    return this._parsers;
  }
  /** Used for testing, this resets the resolver to its initial state */
  reset() {
    this.setBundleIdentifier(this._defaultBundleIdentifierOptions);
    this._assetMap = {};
    this._preferredOrder = [];
    this._resolverHash = {};
    this._rootPath = null;
    this._basePath = null;
    this._manifest = null;
    this._bundles = {};
    this._defaultSearchParams = null;
  }
  /**
   * Sets the default URL search parameters for the URL resolver. The urls can be specified as a string or an object.
   * @param searchParams - the default url parameters to append when resolving urls
   */
  setDefaultSearchParams(searchParams) {
    if (typeof searchParams === "string") {
      this._defaultSearchParams = searchParams;
    } else {
      const queryValues = searchParams;
      this._defaultSearchParams = Object.keys(queryValues).map((key) => `${encodeURIComponent(key)}=${encodeURIComponent(queryValues[key])}`).join("&");
    }
  }
  /**
   * Returns the aliases for a given asset
   * @param asset - the asset to get the aliases for
   */
  getAlias(asset) {
    const { alias, src } = asset;
    const aliasesToUse = convertToList(
      alias || src,
      (value) => {
        if (typeof value === "string") return value;
        if (Array.isArray(value)) return value.map((v) => v?.src ?? v);
        if (value?.src) return value.src;
        return value;
      },
      true
    );
    return aliasesToUse;
  }
  /**
   * Removes the specified alias for an asset.
   *
   * This only removes the alias mapping. It does **not** remove, unload, or destroy the
   * underlying asset. If the asset is already cached, it stays in memory until you call
   * `Assets.unload`.
   *
   * If `asset` is provided, the alias is only removed when the resolver's current mapping for
   * that alias matches the given `ResolvedAsset`. This lets you avoid accidentally removing an
   * alias that has been reassigned.
   *
   * Silently returns if the alias does not exist or the asset does not match.
   * @param alias - the alias to remove
   * @param asset - only remove the alias if it is currently assigned to this asset
   * @example
   * ```ts
   * resolver.add({ alias: 'hero', src: 'hero.png' });
   *
   * // Simple removal
   * resolver.removeAlias('hero');
   *
   * // Conditional removal — only if alias currently maps to a specific asset
   * const resolved = resolver.resolve('hero');
   * resolver.removeAlias('hero', resolved);
   * ```
   */
  removeAlias(alias, asset) {
    if (!this._assetMap[alias]) {
      return;
    }
    if (asset && asset !== this._resolverHash[alias]) {
      return;
    }
    delete this._resolverHash[alias];
    delete this._assetMap[alias];
  }
  /**
   * Add a manifest to the asset resolver. This is a nice way to add all the asset information in one go.
   * generally a manifest would be built using a tool.
   * @param manifest - the manifest to add to the resolver
   */
  addManifest(manifest) {
    if (this._manifest) {
      warn("[Resolver] Manifest already exists, this will be overwritten");
    }
    this._manifest = manifest;
    manifest.bundles.forEach((bundle) => {
      this.addBundle(bundle.name, bundle.assets);
    });
  }
  /**
   * This adds a bundle of assets in one go so that you can resolve them as a group.
   * For example you could add a bundle for each screen in you pixi app
   * @example
   * resolver.addBundle('animals', [
   *  { alias: 'bunny', src: 'bunny.png' },
   *  { alias: 'chicken', src: 'chicken.png' },
   *  { alias: 'thumper', src: 'thumper.png' },
   * ]);
   * // or
   * resolver.addBundle('animals', {
   *     bunny: 'bunny.png',
   *     chicken: 'chicken.png',
   *     thumper: 'thumper.png',
   * });
   *
   * const resolvedAssets = await resolver.resolveBundle('animals');
   * @param bundleId - The id of the bundle to add
   * @param assets - A record of the asset or assets that will be chosen from when loading via the specified key
   */
  addBundle(bundleId, assets) {
    const assetNames = [];
    let convertedAssets = assets;
    if (!Array.isArray(assets)) {
      convertedAssets = Object.entries(assets).map(([alias, src]) => {
        if (typeof src === "string" || Array.isArray(src)) {
          return { alias, src };
        }
        return { alias, ...src };
      });
    }
    convertedAssets.forEach((asset) => {
      const srcs = asset.src;
      const aliases = asset.alias;
      let ids;
      if (typeof aliases === "string") {
        const bundleAssetId = this._createBundleAssetId(bundleId, aliases);
        assetNames.push(bundleAssetId);
        ids = [aliases, bundleAssetId];
      } else {
        const bundleIds = aliases.map((name) => this._createBundleAssetId(bundleId, name));
        assetNames.push(...bundleIds);
        ids = [...aliases, ...bundleIds];
      }
      this.add({
        ...asset,
        ...{
          alias: ids,
          src: srcs
        }
      });
    });
    this._bundles[bundleId] = assetNames;
  }
  /**
   * Tells the resolver what keys are associated with witch asset.
   * The most important thing the resolver does
   * @example
   * // Single key, single asset:
   * resolver.add({alias: 'foo', src: 'bar.png');
   * resolver.resolveUrl('foo') // => 'bar.png'
   *
   * // Multiple keys, single asset:
   * resolver.add({alias: ['foo', 'boo'], src: 'bar.png'});
   * resolver.resolveUrl('foo') // => 'bar.png'
   * resolver.resolveUrl('boo') // => 'bar.png'
   *
   * // Multiple keys, multiple assets:
   * resolver.add({alias: ['foo', 'boo'], src: ['bar.png', 'bar.webp']});
   * resolver.resolveUrl('foo') // => 'bar.png'
   *
   * // Add custom data attached to the resolver
   * Resolver.add({
   *     alias: 'bunnyBooBooSmooth',
   *     src: 'bunny{png,webp}',
   *     data: { scaleMode:SCALE_MODES.NEAREST }, // Base texture options
   * });
   *
   * resolver.resolve('bunnyBooBooSmooth') // => { src: 'bunny.png', data: { scaleMode: SCALE_MODES.NEAREST } }
   * @param aliases - the UnresolvedAsset or array of UnresolvedAssets to add to the resolver
   */
  add(aliases) {
    const assets = [];
    if (Array.isArray(aliases)) {
      assets.push(...aliases);
    } else {
      assets.push(aliases);
    }
    let keyCheck;
    keyCheck = (key) => {
      if (this.hasKey(key)) {
        warn(`[Resolver] already has key: ${key} overwriting`);
      }
    };
    const assetArray = convertToList(assets);
    assetArray.forEach((asset) => {
      const { src } = asset;
      let {
        data,
        format,
        loadParser: userDefinedLoadParser,
        parser: userDefinedParser
      } = asset;
      const srcsToUse = convertToList(src).map((src2) => {
        if (typeof src2 === "string") {
          return createStringVariations(src2);
        }
        return Array.isArray(src2) ? src2 : [src2];
      });
      const aliasesToUse = this.getAlias(asset);
      Array.isArray(aliasesToUse) ? aliasesToUse.forEach(keyCheck) : keyCheck(aliasesToUse);
      const resolvedAssets = [];
      const parseUrl = (url) => {
        const parser = this._parsers.find((p) => p.test(url));
        return {
          src: url,
          ...parser?.parse(url)
        };
      };
      srcsToUse.forEach((srcs) => {
        srcs.forEach((src2) => {
          let formattedAsset = {};
          if (typeof src2 !== "object") {
            formattedAsset = parseUrl(src2);
          } else {
            data = src2.data ?? data;
            format = src2.format ?? format;
            if (src2.loadParser || src2.parser) {
              userDefinedLoadParser = src2.loadParser ?? userDefinedLoadParser;
              userDefinedParser = src2.parser ?? userDefinedParser;
            }
            formattedAsset = {
              ...parseUrl(src2.src),
              ...src2
            };
          }
          if (!aliasesToUse) {
            throw new Error(`[Resolver] alias is undefined for this asset: ${formattedAsset.src}`);
          }
          formattedAsset = this._buildResolvedAsset(formattedAsset, {
            aliases: aliasesToUse,
            data,
            format,
            loadParser: userDefinedLoadParser,
            parser: userDefinedParser,
            progressSize: asset.progressSize
          });
          resolvedAssets.push(formattedAsset);
        });
      });
      aliasesToUse.forEach((alias) => {
        this._assetMap[alias] = resolvedAssets;
      });
    });
  }
  // TODO: this needs an overload like load did in Assets
  /**
   * If the resolver has had a manifest set via setManifest, this will return the assets urls for
   * a given bundleId or bundleIds.
   * @example
   * // Manifest Example
   * const manifest = {
   *     bundles: [
   *         {
   *             name: 'load-screen',
   *             assets: [
   *                 {
   *                     alias: 'background',
   *                     src: 'sunset.png',
   *                 },
   *                 {
   *                     alias: 'bar',
   *                     src: 'load-bar.{png,webp}',
   *                 },
   *             ],
   *         },
   *         {
   *             name: 'game-screen',
   *             assets: [
   *                 {
   *                     alias: 'character',
   *                     src: 'robot.png',
   *                 },
   *                 {
   *                     alias: 'enemy',
   *                     src: 'bad-guy.png',
   *                 },
   *             ],
   *         },
   *     ]
   * };
   *
   * resolver.setManifest(manifest);
   * const resolved = resolver.resolveBundle('load-screen');
   * @param bundleIds - The bundle ids to resolve
   * @returns All the bundles assets or a hash of assets for each bundle specified
   */
  resolveBundle(bundleIds) {
    const singleAsset = isSingleItem(bundleIds);
    bundleIds = convertToList(bundleIds);
    const out = {};
    bundleIds.forEach((bundleId) => {
      const assetNames = this._bundles[bundleId];
      if (assetNames) {
        const results = this.resolve(assetNames);
        const assets = {};
        for (const key in results) {
          const asset = results[key];
          assets[this._extractAssetIdFromBundle(bundleId, key)] = asset;
        }
        out[bundleId] = assets;
      }
    });
    return singleAsset ? out[bundleIds[0]] : out;
  }
  /**
   * Does exactly what resolve does, but returns just the URL rather than the whole asset object
   * @param key - The key or keys to resolve
   * @returns - The URLs associated with the key(s)
   */
  resolveUrl(key) {
    const result = this.resolve(key);
    if (typeof key !== "string") {
      const out = {};
      for (const i in result) {
        out[i] = result[i].src;
      }
      return out;
    }
    return result.src;
  }
  resolve(keys) {
    const singleAsset = isSingleItem(keys);
    keys = convertToList(keys);
    const result = {};
    keys.forEach((key) => {
      if (!this._resolverHash[key]) {
        if (this._assetMap[key]) {
          let assets = this._assetMap[key];
          const preferredOrder = this._getPreferredOrder(assets);
          preferredOrder?.priority.forEach((priorityKey) => {
            preferredOrder.params[priorityKey].forEach((value) => {
              const filteredAssets = assets.filter((asset) => {
                if (asset[priorityKey]) {
                  return asset[priorityKey] === value;
                }
                return false;
              });
              if (filteredAssets.length) {
                assets = filteredAssets;
              }
            });
          });
          this._resolverHash[key] = assets[0];
        } else {
          this._resolverHash[key] = this._buildResolvedAsset({
            alias: [key],
            src: key
          }, {});
        }
      }
      result[key] = this._resolverHash[key];
    });
    return singleAsset ? result[keys[0]] : result;
  }
  /**
   * Checks if an asset with a given key exists in the resolver
   * @param key - The key of the asset
   */
  hasKey(key) {
    return !!this._assetMap[key];
  }
  /**
   * Checks if a bundle with the given key exists in the resolver
   * @param key - The key of the bundle
   */
  hasBundle(key) {
    return !!this._bundles[key];
  }
  /**
   * Internal function for figuring out what prefer criteria an asset should use.
   * @param assets
   */
  _getPreferredOrder(assets) {
    for (let i = 0; i < assets.length; i++) {
      const asset = assets[i];
      const preferred = this._preferredOrder.find((preference) => preference.params.format.includes(asset.format));
      if (preferred) {
        return preferred;
      }
    }
    return this._preferredOrder[0];
  }
  /**
   * Appends the default url parameters to the url
   * @param url - The url to append the default parameters to
   * @returns - The url with the default parameters appended
   */
  _appendDefaultSearchParams(url) {
    if (!this._defaultSearchParams) return url;
    const paramConnector = /\?/.test(url) ? "&" : "?";
    return `${url}${paramConnector}${this._defaultSearchParams}`;
  }
  _buildResolvedAsset(formattedAsset, data) {
    const { aliases, data: assetData, loadParser, parser, format, progressSize } = data;
    if (this._basePath || this._rootPath) {
      formattedAsset.src = path.toAbsolute(formattedAsset.src, this._basePath, this._rootPath);
    }
    formattedAsset.alias = aliases ?? formattedAsset.alias ?? [formattedAsset.src];
    formattedAsset.src = this._appendDefaultSearchParams(formattedAsset.src);
    formattedAsset.data = { ...assetData || {}, ...formattedAsset.data };
    formattedAsset.loadParser = loadParser ?? formattedAsset.loadParser;
    formattedAsset.parser = parser ?? formattedAsset.parser;
    formattedAsset.format = format ?? formattedAsset.format ?? getUrlExtension(formattedAsset.src);
    if (progressSize !== void 0) {
      formattedAsset.progressSize = progressSize;
    }
    return formattedAsset;
  }
}
/**
 * The prefix that denotes a URL is for a retina asset.
 * @default /@([0-9\.]+)x/
 * @example `@2x`
 */
Resolver.RETINA_PREFIX = /@([0-9\.]+)x/;
function getUrlExtension(url) {
  return url.split(".").pop().split("?").shift().split("#").shift();
}

export { Resolver, getUrlExtension };
//# sourceMappingURL=Resolver.mjs.map
