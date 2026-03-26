'use strict';

var adapter = require('../../../../environment/adapter.js');
var Extensions = require('../../../../extensions/Extensions.js');
var ImageSource = require('../../../../rendering/renderers/shared/texture/sources/ImageSource.js');
var getResolutionOfUrl = require('../../../../utils/network/getResolutionOfUrl.js');
var checkDataUrl = require('../../../utils/checkDataUrl.js');
var checkExtension = require('../../../utils/checkExtension.js');
var WorkerManager = require('../../workers/WorkerManager.js');
var LoaderParser = require('../LoaderParser.js');
var createTexture = require('./utils/createTexture.js');

"use strict";
const validImageExtensions = [".jpeg", ".jpg", ".png", ".webp", ".avif"];
const validImageMIMEs = [
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/avif"
];
async function loadImageBitmap(url, asset) {
  const response = await adapter.DOMAdapter.get().fetch(url);
  if (!response.ok) {
    throw new Error(`[loadImageBitmap] Failed to fetch ${url}: ${response.status} ${response.statusText}`);
  }
  const imageBlob = await response.blob();
  return asset?.data?.alphaMode === "premultiplied-alpha" ? createImageBitmap(imageBlob, { premultiplyAlpha: "none" }) : createImageBitmap(imageBlob);
}
const loadTextures = {
  /** used for deprecation purposes */
  name: "loadTextures",
  id: "texture",
  extension: {
    type: Extensions.ExtensionType.LoadParser,
    priority: LoaderParser.LoaderParserPriority.High,
    name: "loadTextures"
  },
  config: {
    preferWorkers: true,
    preferCreateImageBitmap: true,
    crossOrigin: "anonymous"
  },
  test(url) {
    return checkDataUrl.checkDataUrl(url, validImageMIMEs) || checkExtension.checkExtension(url, validImageExtensions);
  },
  async load(url, asset, loader) {
    let src = null;
    if (globalThis.createImageBitmap && this.config.preferCreateImageBitmap) {
      if (this.config.preferWorkers && await WorkerManager.WorkerManager.isImageBitmapSupported()) {
        src = await WorkerManager.WorkerManager.loadImageBitmap(url, asset);
      } else {
        src = await loadImageBitmap(url, asset);
      }
    } else {
      src = await new Promise((resolve, reject) => {
        src = adapter.DOMAdapter.get().createImage();
        src.crossOrigin = this.config.crossOrigin;
        src.src = url;
        if (src.complete) {
          resolve(src);
        } else {
          src.onload = () => {
            resolve(src);
          };
          src.onerror = reject;
        }
      });
    }
    const base = new ImageSource.ImageSource({
      resource: src,
      alphaMode: "premultiply-alpha-on-upload",
      resolution: asset.data?.resolution || getResolutionOfUrl.getResolutionOfUrl(url),
      ...asset.data
    });
    return createTexture.createTexture(base, loader, url);
  },
  unload(texture) {
    texture.destroy(true);
  }
};

exports.loadImageBitmap = loadImageBitmap;
exports.loadTextures = loadTextures;
//# sourceMappingURL=loadTextures.js.map
