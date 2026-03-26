'use strict';

var LoaderParser = require('../assets/loader/parsers/LoaderParser.js');
var Resolver = require('../assets/resolver/Resolver.js');
var copySearchParams = require('../assets/utils/copySearchParams.js');
var Extensions = require('../extensions/Extensions.js');
var Texture = require('../rendering/renderers/shared/texture/Texture.js');
var path = require('../utils/path.js');
var Spritesheet = require('./Spritesheet.js');

"use strict";
const validImages = [
  "jpg",
  "png",
  "jpeg",
  "avif",
  "webp",
  "basis",
  "etc2",
  "bc7",
  "bc6h",
  "bc5",
  "bc4",
  "bc3",
  "bc2",
  "bc1",
  "eac",
  "astc"
];
function getCacheableAssets(keys, asset, ignoreMultiPack) {
  const out = {};
  keys.forEach((key) => {
    out[key] = asset;
  });
  Object.keys(asset.textures).forEach((key) => {
    out[`${asset.cachePrefix}${key}`] = asset.textures[key];
  });
  if (!ignoreMultiPack) {
    const basePath = path.path.dirname(keys[0]);
    asset.linkedSheets.forEach((item, i) => {
      const out2 = getCacheableAssets([`${basePath}/${asset.data.meta.related_multi_packs[i]}`], item, true);
      Object.assign(out, out2);
    });
  }
  return out;
}
const spritesheetAsset = {
  extension: Extensions.ExtensionType.Asset,
  /** Handle the caching of the related Spritesheet Textures */
  cache: {
    test: (asset) => asset instanceof Spritesheet.Spritesheet,
    getCacheableAssets: (keys, asset) => getCacheableAssets(keys, asset, false)
  },
  /** Resolve the resolution of the asset. */
  resolver: {
    extension: {
      type: Extensions.ExtensionType.ResolveParser,
      name: "resolveSpritesheet"
    },
    test: (value) => {
      const tempURL = value.split("?")[0];
      const split = tempURL.split(".");
      const extension = split.pop();
      const format = split.pop();
      return extension === "json" && validImages.includes(format);
    },
    parse: (value) => {
      const split = value.split(".");
      return {
        resolution: parseFloat(Resolver.Resolver.RETINA_PREFIX.exec(value)?.[1] ?? "1"),
        format: split[split.length - 2],
        src: value
      };
    }
  },
  /**
   * Loader plugin that parses sprite sheets!
   * once the JSON has been loaded this checks to see if the JSON is spritesheet data.
   * If it is, we load the spritesheets image and parse the data into Spritesheet
   * All textures in the sprite sheet are then added to the cache
   */
  loader: {
    /** used for deprecation purposes */
    name: "spritesheetLoader",
    id: "spritesheet",
    extension: {
      type: Extensions.ExtensionType.LoadParser,
      priority: LoaderParser.LoaderParserPriority.Normal,
      name: "spritesheetLoader"
    },
    async testParse(asset, options) {
      return path.path.extname(options.src).toLowerCase() === ".json" && !!asset.frames;
    },
    async parse(asset, options, loader) {
      const {
        texture: imageTexture,
        // if user need to use preloaded texture
        imageFilename,
        // if user need to use custom filename (not from jsonFile.meta.image)
        textureOptions,
        // if user need to set texture options on texture
        cachePrefix
        // if user need to use custom cache prefix
      } = options?.data ?? {};
      let basePath = path.path.dirname(options.src);
      if (basePath && basePath.lastIndexOf("/") !== basePath.length - 1) {
        basePath += "/";
      }
      let texture;
      if (imageTexture instanceof Texture.Texture) {
        texture = imageTexture;
      } else {
        const imagePath = copySearchParams.copySearchParams(basePath + (imageFilename ?? asset.meta.image), options.src);
        const assets = await loader.load([{ src: imagePath, data: textureOptions }]);
        texture = assets[imagePath];
      }
      const spritesheet = new Spritesheet.Spritesheet({
        texture: texture.source,
        data: asset,
        cachePrefix
      });
      await spritesheet.parse();
      const multiPacks = asset?.meta?.related_multi_packs;
      if (Array.isArray(multiPacks)) {
        const promises = [];
        for (const item of multiPacks) {
          if (typeof item !== "string") {
            continue;
          }
          let itemUrl = basePath + item;
          if (options.data?.ignoreMultiPack) {
            continue;
          }
          itemUrl = copySearchParams.copySearchParams(itemUrl, options.src);
          promises.push(loader.load({
            src: itemUrl,
            data: {
              textureOptions,
              ignoreMultiPack: true
            }
          }));
        }
        const res = await Promise.all(promises);
        spritesheet.linkedSheets = res;
        res.forEach((item) => {
          item.linkedSheets = [spritesheet].concat(spritesheet.linkedSheets.filter((sp) => sp !== item));
        });
      }
      return spritesheet;
    },
    async unload(spritesheet, _resolvedAsset, loader) {
      await loader.unload(spritesheet.textureSource._sourceOrigin);
      spritesheet.destroy(false);
    }
  }
};

exports.spritesheetAsset = spritesheetAsset;
//# sourceMappingURL=spritesheetAsset.js.map
