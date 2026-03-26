import { LoaderParserPriority } from '../../../assets/loader/parsers/LoaderParser.mjs';
import { copySearchParams } from '../../../assets/utils/copySearchParams.mjs';
import { DOMAdapter } from '../../../environment/adapter.mjs';
import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { path } from '../../../utils/path.mjs';
import { bitmapFontTextParser } from './bitmapFontTextParser.mjs';
import { bitmapFontXMLStringParser } from './bitmapFontXMLStringParser.mjs';

"use strict";
const validExtensions = [".xml", ".fnt"];
const bitmapFontCachePlugin = {
  extension: {
    type: ExtensionType.CacheParser,
    name: "cacheBitmapFont"
  },
  test: (asset) => !!asset?.pages && !!asset?.chars && typeof asset?.fontFamily === "string" && asset.fontFamily !== "",
  getCacheableAssets(keys, asset) {
    const out = {};
    keys.forEach((key) => {
      out[key] = asset;
      out[`${key}-bitmap`] = asset;
    });
    out[`${asset.fontFamily}-bitmap`] = asset;
    return out;
  }
};
const loadBitmapFont = {
  extension: {
    type: ExtensionType.LoadParser,
    priority: LoaderParserPriority.Normal
  },
  /** used for deprecation purposes */
  name: "loadBitmapFont",
  id: "bitmap-font",
  test(url) {
    return validExtensions.includes(path.extname(url).toLowerCase());
  },
  async testParse(data) {
    return bitmapFontTextParser.test(data) || bitmapFontXMLStringParser.test(data);
  },
  async parse(asset, data, loader) {
    const bitmapFontData = bitmapFontTextParser.test(asset) ? bitmapFontTextParser.parse(asset) : bitmapFontXMLStringParser.parse(asset);
    const { src } = data;
    const { pages } = bitmapFontData;
    const textureUrls = [];
    const textureOptions = bitmapFontData.distanceField ? {
      scaleMode: "linear",
      alphaMode: "premultiply-alpha-on-upload",
      autoGenerateMipmaps: false,
      resolution: 1
    } : {};
    for (let i = 0; i < pages.length; ++i) {
      const pageFile = pages[i].file;
      let imagePath = path.join(path.dirname(src), pageFile);
      imagePath = copySearchParams(imagePath, src);
      textureUrls.push({
        src: imagePath,
        data: textureOptions
      });
    }
    const [loadedTextures, { BitmapFont }] = await Promise.all([
      loader.load(textureUrls),
      import('../BitmapFont.mjs')
    ]);
    const textures = textureUrls.map((url) => loadedTextures[url.src]);
    const bitmapFont = new BitmapFont({
      data: bitmapFontData,
      textures
    }, src);
    return bitmapFont;
  },
  async load(url, _options) {
    const response = await DOMAdapter.get().fetch(url);
    return await response.text();
  },
  async unload(bitmapFont, _resolvedAsset, loader) {
    await Promise.all(bitmapFont.pages.map((page) => loader.unload(page.texture.source._sourceOrigin)));
    bitmapFont.destroy();
  }
};

export { bitmapFontCachePlugin, loadBitmapFont };
//# sourceMappingURL=loadBitmapFont.mjs.map
