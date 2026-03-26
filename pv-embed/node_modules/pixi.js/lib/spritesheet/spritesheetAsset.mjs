import { LoaderParserPriority } from '../assets/loader/parsers/LoaderParser.mjs';
import { Resolver } from '../assets/resolver/Resolver.mjs';
import { copySearchParams } from '../assets/utils/copySearchParams.mjs';
import { ExtensionType } from '../extensions/Extensions.mjs';
import { Texture } from '../rendering/renderers/shared/texture/Texture.mjs';
import { path } from '../utils/path.mjs';
import { Spritesheet } from './Spritesheet.mjs';

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
    const basePath = path.dirname(keys[0]);
    asset.linkedSheets.forEach((item, i) => {
      const out2 = getCacheableAssets([`${basePath}/${asset.data.meta.related_multi_packs[i]}`], item, true);
      Object.assign(out, out2);
    });
  }
  return out;
}
const spritesheetAsset = {
  extension: ExtensionType.Asset,
  /** Handle the caching of the related Spritesheet Textures */
  cache: {
    test: (asset) => asset instanceof Spritesheet,
    getCacheableAssets: (keys, asset) => getCacheableAssets(keys, asset, false)
  },
  /** Resolve the resolution of the asset. */
  resolver: {
    extension: {
      type: ExtensionType.ResolveParser,
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
        resolution: parseFloat(Resolver.RETINA_PREFIX.exec(value)?.[1] ?? "1"),
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
      type: ExtensionType.LoadParser,
      priority: LoaderParserPriority.Normal,
      name: "spritesheetLoader"
    },
    async testParse(asset, options) {
      return path.extname(options.src).toLowerCase() === ".json" && !!asset.frames;
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
      let basePath = path.dirname(options.src);
      if (basePath && basePath.lastIndexOf("/") !== basePath.length - 1) {
        basePath += "/";
      }
      let texture;
      if (imageTexture instanceof Texture) {
        texture = imageTexture;
      } else {
        const imagePath = copySearchParams(basePath + (imageFilename ?? asset.meta.image), options.src);
        const assets = await loader.load([{ src: imagePath, data: textureOptions }]);
        texture = assets[imagePath];
      }
      const spritesheet = new Spritesheet({
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
          itemUrl = copySearchParams(itemUrl, options.src);
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

export { spritesheetAsset };
//# sourceMappingURL=spritesheetAsset.mjs.map
