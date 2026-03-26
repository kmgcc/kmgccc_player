import { DOMAdapter } from '../../../../environment/adapter.mjs';
import { ExtensionType } from '../../../../extensions/Extensions.mjs';
import { ImageSource } from '../../../../rendering/renderers/shared/texture/sources/ImageSource.mjs';
import { getResolutionOfUrl } from '../../../../utils/network/getResolutionOfUrl.mjs';
import { checkDataUrl } from '../../../utils/checkDataUrl.mjs';
import { checkExtension } from '../../../utils/checkExtension.mjs';
import { WorkerManager } from '../../workers/WorkerManager.mjs';
import { LoaderParserPriority } from '../LoaderParser.mjs';
import { createTexture } from './utils/createTexture.mjs';

"use strict";
const validImageExtensions = [".jpeg", ".jpg", ".png", ".webp", ".avif"];
const validImageMIMEs = [
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/avif"
];
async function loadImageBitmap(url, asset) {
  const response = await DOMAdapter.get().fetch(url);
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
    type: ExtensionType.LoadParser,
    priority: LoaderParserPriority.High,
    name: "loadTextures"
  },
  config: {
    preferWorkers: true,
    preferCreateImageBitmap: true,
    crossOrigin: "anonymous"
  },
  test(url) {
    return checkDataUrl(url, validImageMIMEs) || checkExtension(url, validImageExtensions);
  },
  async load(url, asset, loader) {
    let src = null;
    if (globalThis.createImageBitmap && this.config.preferCreateImageBitmap) {
      if (this.config.preferWorkers && await WorkerManager.isImageBitmapSupported()) {
        src = await WorkerManager.loadImageBitmap(url, asset);
      } else {
        src = await loadImageBitmap(url, asset);
      }
    } else {
      src = await new Promise((resolve, reject) => {
        src = DOMAdapter.get().createImage();
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
    const base = new ImageSource({
      resource: src,
      alphaMode: "premultiply-alpha-on-upload",
      resolution: asset.data?.resolution || getResolutionOfUrl(url),
      ...asset.data
    });
    return createTexture(base, loader, url);
  },
  unload(texture) {
    texture.destroy(true);
  }
};

export { loadImageBitmap, loadTextures };
//# sourceMappingURL=loadTextures.mjs.map
