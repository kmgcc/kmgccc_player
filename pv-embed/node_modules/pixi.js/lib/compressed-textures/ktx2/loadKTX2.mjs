import { LoaderParserPriority } from '../../assets/loader/parsers/LoaderParser.mjs';
import { createTexture } from '../../assets/loader/parsers/textures/utils/createTexture.mjs';
import { checkExtension } from '../../assets/utils/checkExtension.mjs';
import { ExtensionType } from '../../extensions/Extensions.mjs';
import { CompressedSource } from '../../rendering/renderers/shared/texture/sources/CompressedSource.mjs';
import { getSupportedTextureFormats } from '../../rendering/renderers/shared/texture/utils/getSupportedTextureFormats.mjs';
import { getResolutionOfUrl } from '../../utils/network/getResolutionOfUrl.mjs';
import { loadKTX2onWorker } from './worker/loadKTX2onWorker.mjs';

"use strict";
const loadKTX2 = {
  extension: {
    type: ExtensionType.LoadParser,
    priority: LoaderParserPriority.High,
    name: "loadKTX2"
  },
  /** used for deprecation purposes */
  name: "loadKTX2",
  id: "ktx2",
  test(url) {
    return checkExtension(url, ".ktx2");
  },
  async load(url, asset, loader) {
    const supportedTextures = await getSupportedTextureFormats();
    const textureOptions = await loadKTX2onWorker(url, supportedTextures);
    const compressedTextureSource = new CompressedSource({
      ...textureOptions,
      resolution: asset.data?.resolution || getResolutionOfUrl(url)
    });
    return createTexture(compressedTextureSource, loader, url);
  },
  async unload(texture) {
    if (Array.isArray(texture)) {
      texture.forEach((t) => t.destroy(true));
    } else {
      texture.destroy(true);
    }
  }
};

export { loadKTX2 };
//# sourceMappingURL=loadKTX2.mjs.map
